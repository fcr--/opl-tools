local oo = require 'lualib.oo'

local Iso = oo.class()
Iso.Dirent = oo.class()
Iso.File = oo.class()

function Iso:_init(fd)
   self.fd = fd
   self:load_volume_descriptors()
end

local function read_u32l(str, pos)
   local b0, b1, b2, b3 = str:byte(pos, pos + 3)
   return ((b3*256 + b2)*256 + b1)*256 + b0
end

function Iso.Dirent:_init(sector, dirent_pos_in_sector)
   --dirent_size = sector:byte(dirent_pos_in_sector)
   --print(('dirent at 0x%x, size = %d'):format(dirent_pos_in_sector-1, dirent_size))
   self.location_lba = read_u32l(sector, dirent_pos_in_sector + 2)
   self.size = read_u32l(sector, dirent_pos_in_sector + 10)
   local flags = sector:byte(dirent_pos_in_sector + 25)
   local file_name_length = sector:byte(dirent_pos_in_sector + 32)
   --print('file_name_length:', file_name_length)
   self.name = sector:sub(dirent_pos_in_sector+33, dirent_pos_in_sector+33+file_name_length-1)
   self.is_hidden = flags % 2 == 1
   self.is_dir = math.floor(flags/2) % 2 == 1
end

function Iso:load_volume_descriptors()
   assert(self.fd:seek('set', 32768))
   while true do
      local sector = assert(self.fd:read(2048))
      assert(sector:match '^.CD001\1')
      assert(#sector == 2048, 'unexpected EOF')
      local desc_type = sector:byte(1)

      --print('desc_type:', desc_type)
      if desc_type == 1 then
         --print 'Primary Volume Descriptor'
         -- root_dirent is at bytes 157..190 (1-base index)
         self.root_dirent = self.Dirent:new(sector, 157)
      elseif desc_type == 255 then
         -- print 'Volume Descriptor Set Terminator'
         break
      end
   end
end

function Iso:_opendir(location_lba, size)
   local sector, dirent_pos_in_sector

   return function()
      while size > 0 do
         if not sector or dirent_pos_in_sector > 2048 then
            assert(self.fd:seek('set', 2048 * location_lba))
            sector = assert(self.fd:read(2048))
            assert(#sector == 2048)
            location_lba = location_lba + 1
            dirent_pos_in_sector = 1
         end
         local dirent_size = sector:byte(dirent_pos_in_sector)
         if dirent_size == 0 then
            dirent_pos_in_sector = dirent_pos_in_sector + 1
            size = size - 1
         else
            local dirent = self.Dirent:new(sector, dirent_pos_in_sector)
            dirent_pos_in_sector = dirent_pos_in_sector + dirent_size
            size = size - dirent_size
            -- ignore dirents for current and parent directory:
            if dirent.name ~= '\0' and dirent.name ~= '\1' then
               return dirent
            end
         end
      end
      return nil
   end
end

function Iso:_find_dirent(path)
   assert(path:match '^/')
   local d = self.root_dirent
   for component in path:gmatch '/([^/]+)' do
      component = component:upper()
      local found = false
      for dirent in self:_opendir(d.location_lba, d.size) do
         if component == dirent.name:upper() then
            assert(d.is_dir, 'not a directory')
            d = dirent
            found = true
            break
         end
      end
      if not found then
         error 'no such file or directory'
      end
   end
   return d
end

function Iso:dir(path)
   local dirent = self:_find_dirent(path:upper())
   return self:_opendir(dirent.location_lba, dirent.size)
end

function Iso.File:_init(fd, extents)
   self.fd = fd
   self.extents = extents
   local total_size = 0
   for _, extent in ipairs(extents) do
      total_size = total_size + extent.size
   end
   self.size = total_size
   self.offset = 0
end

function Iso.File:seek(whence, offset)
   offset = math.floor(offset or 0)
   if whence == 'set' then
   elseif whence == 'cur' then
      offset = self.offset + offset
   elseif whence == 'end' then
      offset = self.size + offset
   end
   if offset < 0 then return nil, 'Invalid argument', 22 end
   self.offset = offset
   return offset
end

function Iso.File:read(nbytes)
   if nbytes == '*a' or nbytes == 'a' then
      nbytes = math.max(self.size - self.offset, 0)
   end

   -- find extent:
   local offset_in_extent = self.offset
   local extent_index = 1
   while self.extents[extent_index] and offset_in_extent >= self.extents[extent_index].size do
      offset_in_extent = offset_in_extent - self.extents[extent_index].size
      extent_index = extent_index + 1
      --print('skipping extent', extent_index)
   end
   local extent = self.extents[extent_index]
   if not extent then return nil end
   local blocks

   if nbytes <= 0 then return "" end
   repeat
      local bytes_to_read = math.min(nbytes, extent.size - offset_in_extent)
      self.fd:seek('set', extent.location_lba*2048 + offset_in_extent)
      local bytes = self.fd:read(bytes_to_read)
      if not bytes or #bytes < bytes_to_read then error 'iso short read' end

      self.offset = self.offset + #bytes
      local nbytes = nbytes - #bytes

      -- optimization: let's avoid table.concat for reads within a single extent
      if bytes_to_read == nbytes then
         return bytes
      end
      -- NOTE: Fragmentation support is not well tested
      if not blocks then
         blocks = {}
         offset_in_extent = 0
      end
      -- add chunk and move to next extent:
      blocks[#blocks+1] = bytes
      extent_index = extent_index + 1
      extent = self.extents[extent_index]
   until nbytes <= 0 or not extent
   return table.concat(blocks)
end

function Iso:open(path)
   local dirname, basename = path:upper():match '(.*/)([^/]+)$'
   assert(basename, 'invalid path')
   local parentdir = self:_find_dirent(dirname)
   local extents = {}
   for dirent in self:_opendir(parentdir.location_lba, parentdir.size) do
      if basename == dirent.name:upper() then
         assert(not dirent.is_dir, 'is a directory')
         table.insert(extents, {location_lba=dirent.location_lba, size=dirent.size})
      end
   end
   if not extents[1] then
      error 'no such file or directory'
   end
   return self.File:new(self.fd, extents)
end

if os.getenv 'TEST_ISO' then
   local iso = Iso:new(assert(io.open(os.getenv'TEST_ISO')))
   --print(iso.root_location_lba, iso.root_size)
   for dirent in iso:dir '/modules' do
      print(('%-14s %10d %10d %s%s'):format(dirent.name, dirent.location_lba, dirent.size,
         dirent.is_hidden and 'H' or '-', dirent.is_dir and 'D' or '-'))
   end
   local siofd = iso:open '/modules/Sio2D.IRX;1'
   print('sio2d.irx size:', siofd.size, '==', #siofd:read(12000))
   print(iso:open '/SYSTEM.CNF;1':read'*a')
end

return Iso
