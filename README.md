# INSTALL

Easiest altertnative if you don't want to use a lua virtual environment or custom luarocks tree:
```
sudo luarocks install --global lua-lz4 luafilesystem
sudo apt install imagemagick
```

# RUNNING

## add-missing-images.lua
This tool can be used to add any missing cover ART to the standard OPL folder structure.
The source images must be already downloaded, for which you can `git clone` the https://github.com/xlenore/ps2-covers repo,
or download that repo as a zip file and extract it somewhere in your disk drive.

Example (remove `-dry-run` to actually execute the commands):
```
./add-missing-images.lua -dir /media/fran/mx4sio/ -covers ../ps2-covers/ -dry-run
```

Limitations:
* Only `.iso` and `.zso` files are supported, and only in the DVD folder.  In other words no "CD/" nor split files from `ul.cfg`.
* Source images must be in jpg format and with a pretty strict file name format, eg: `SLPM-12345.jpg`.
* Target images are scaled to 140xH pixels.
