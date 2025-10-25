local lz4 = require 'lz4'
local oo = require 'lualib.oo'
local Iso = require 'iso'

local Ziso = oo.class()

local function read_u32l(str, pos)
   local b0, b1, b2, b3 = str:byte(pos, pos + 3)
   return ((b3*256 + b2)*256 + b1)*256 + b0
end

function Ziso:_init(fd)
   self.fd = fd
   self.offset = 0
   assert(fd:seek('set', 0))
   local header = assert(fd:read(24))
   -- magic ZISO followed by header size:
   assert(header:match '^ZISO\24\0\0\0')

   -- 64 unsigned bits at offset 8 (position 9):
   local total_size_lo = read_u32l(header, 9)
   local total_size_hi = read_u32l(header, 13)
   self.total_size = total_size_hi * 2^32 + total_size_lo
   assert(self.total_size<2^53, 'file >= 2^53')

   self.block_size = read_u32l(header, 17)
   local version = header:byte(21)
   self.align = 2^header:byte(22)

   assert(version == 1, 'unsupported ziso version')
   self.total_blocks = math.ceil(self.total_size / self.block_size)
   self.index_string = assert(fd:read(4 * self.total_blocks))
   assert(#self.index_string == 4 * self.total_blocks, 'short read on index table')
end

function Ziso:index(block)
   -- returns:
   --   * the start offset (position in self.fd) for the block,
   --   * its compressed size in bytes,
   --   * and a boolean indicating it is plain text.
   assert(block >= 0, 'negative block index')
   assert(block < self.total_blocks, 'block index too large')
   local plain = false
   local block_offset = read_u32l(self.index_string, 4*block+1)
   if block_offset >= 0x80000000 then
      block_offset = block_offset - 0x80000000
      plain = true
   end
   local read_pos = block_offset * self.align
   local size
   if block < self.total_blocks - 1 then
      local next_block_offset = read_u32l(self.index_string, 4*block+5)
      if next_block_offset >= 0x80000000 then
         next_block_offset = next_block_offset - 0x80000000
      end
      size = next_block_offset * self.align - read_pos
   else
      -- for the size of the last block we have to compute against the total
      -- size as there's no next block:
      size = self.total_size - read_pos
   end

   return read_pos, size, plain
end

function Ziso:seek(whence, offset)
   if not self.fd then error 'closed' end
   offset = math.floor(offset or 0)
   if whence == 'set' then
   elseif whence == 'cur' then
      offset = self.offset + offset
   elseif whence == 'end' then
      offset = self.total_size + offset
   end
   if offset < 0 then return nil, 'Invalid argument', 22 end
   self.offset = offset
   return offset
end

function Ziso:read(nbytes)
   --print(('read %d bytes at offset=0x%x'):format(nbytes, self.offset))
   if not self.fd then error 'closed' end
   if self.offset >= self.total_size then return nil end
   local chunks = {}
   while nbytes > 0 do
      -- let's first read the whole block:
      local block_index = math.floor(self.offset / self.block_size)
      local read_pos, csize, plain = self:index(block_index)
      assert(self.fd:seek('set', read_pos))
      local data = assert(self.fd:read(csize))
      if not plain then
         --print(('offset=0x%x, read_pos=%d, block_index=%d, csize=%d, #data=%d, block_size=%d, data=b"%s"'):format(
         --   self.offset, read_pos, block_index, csize, #data, self.block_size,
         --   (data:gsub('.', function(c)return ('\\x%02x'):format(c:byte())end))))
         local ok, uncompressed
         for i = 1, self.align do
            ok, uncompressed = pcall(lz4.block_decompress_safe, data, self.block_size)
            if ok then
               data = uncompressed
               -- print('ok', i)
               break
            else
               data = data:sub(1, -2)
            end
         end
         if not ok then error('error uncompressing byte', uncompressed) end
      end
      -- remove leading and trailing data:
      local leading_bytes = self.offset % self.block_size
      if leading_bytes > 0 then
         data = data:sub(leading_bytes+1)
      end
      if nbytes < #data then
         data = data:sub(1, nbytes)
      end

      nbytes = nbytes - #data
      self.offset = self.offset + #data
      chunks[#chunks+1] = data
   end
   if #chunks < 2 then return chunks[1] or "" end
   return table.concat(chunks)
end

function Ziso:close()
   self.fd:close()
   self.fd = nil
end

if os.getenv 'TEST_ZISO' then
   local iso = Iso:new(Ziso:new(assert(io.open(os.getenv'TEST_ZISO'))))
   --print(iso.root_location_lba, iso.root_size)
   for dirent in iso:dir '/' do
      print(('%-14s %10d %10d %s%s'):format(dirent.name, dirent.location_lba, dirent.size,
         dirent.is_hidden and 'H' or '-', dirent.is_dir and 'D' or '-'))
   end
   print(iso:open '/System.CNF;1':read'*a')
end

return Ziso
