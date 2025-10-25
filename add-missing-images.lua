#!/usr/bin/env luajit
local Iso = require 'iso'
local Ziso = require 'ziso'
local lfs = require 'lfs'

local valid_options = {
   ['-dir'] = {
      param='dir',
      attribute='dir',
      description='OPL directory that contains folders such as DVD, ART, ...',
   },
   ['-covers'] = {
      param='dir',
      attribute='covers',
      description='Path to ps2-covers repo or folder with the cover images',
   },
   ['-dry-run'] = {
      attribute='dry_run',
      description='Show the commands that would be run without executing them',
   },
   ['-debug'] = {
      attribute='debug',
      description='Print more information to help development and debugging',
   },
}

local function print_options()
   print 'add-missing-images.lua [options]:'

   for k, opt in pairs(valid_options) do
      if opt.param then
         print(('   %s <%s>: %s'):format(k, opt.param, opt.description))
      else
         print(('   %s: %s'):format(k, opt.description))
      end
   end
   os.exit()
end

local function parse_args(arg)
   local options = {}
   if #arg == 0 or arg[1] == '--help' then
      print_options()
   end

   local i = 1
   while i <= #arg do
      local opt, value = valid_options[arg[i]], true
      if not opt then print_options() end
      if opt.param then
         value = arg[i+1]
         if not value then print_options() end
         i = i + 1
      end
      options[opt.attribute] = value
      i = i + 1
   end
   return options
end

local options = parse_args(arg)
assert(assert(lfs.attributes(options.dir)).mode == 'directory')

if not lfs.attributes(options.dir .. '/DVD') then
   print('missing DVD folder in:', options.dir)
   os.exit()
end

local function get_covers_dir(path)
   if not path or not lfs.attributes(path) then
      print('Missing or invalid -covers parameter')
      os.exit()
   end
   if lfs.attributes(path..'/ps2-covers') then
      path = path..'/ps2-covers/covers/default'
   end
   assert(lfs.attributes(path).mode == 'directory')
   return path
end

local covers_dir = get_covers_dir(options.covers)

local function debug(format, ...)
   if options.debug then print(format:format(...)) end
end

local function process_file(file)
   local fd = assert(io.open(file))
   local header = assert(fd:read(4))
   if header == 'ZISO' then
      fd = Ziso:new(fd)
      debug '  ziso file found'
   end
   local iso = Iso:new(fd)
   local system_settings = {}
   for system_line in iso:open '/system.cnf;1':read '*a':gmatch '[^\r\n]+' do
      local key, value = system_line:match '^%s*([^=]-)%s*=%s*(.-)%s*$'
      if not key or not value then error('parsing:' .. system_line) end
      system_settings[key:lower()] = value
   end
   debug('  raw boot2: %q', system_settings.boot2)

   local boot2 = system_settings.boot2:upper():match '^CDROM0:\\([A-Z]+_[0-9]+%.[0-9]+);1$'
   if not boot2 then error('wrong boot2 name: '..system_settings.boot2) end
   debug('  boot2: %q', boot2)

   local input_file = covers_dir .. '/' .. boot2:gsub('_', '-'):gsub('%.', '') .. '.jpg'
   local output_file = options.dir .. '/ART/' .. boot2 .. '_COV.jpg'
   if not lfs.attributes(input_file) then
      print('\27[1;31mwarning\27[0m: missing source image:', input_file)
   end
   if not lfs.attributes(output_file) then
      local convert = ("convert '%s' -resize 140x '%s'"):format(
         input_file,
         output_file)
      if not lfs.attributes(input_file) then
         error('missing input file: ' .. input_file)
      end
      print(convert..'; file='..file)
      if not options.dry_run then os.execute(convert) end
   end
   fd:close()
end

for file in lfs.dir(options.dir .. '/DVD') do
   if file:match '^%.' or file:lower() == 'games.bin' then goto continue end
   debug('file: %s', file)
   local ok, err = pcall(process_file, options.dir..'/DVD/'..file)
   if not ok then
      print('error processing file:', file, 'error:', err)
   end
   ::continue::
end
