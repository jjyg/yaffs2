YaFFS2 disk image parser


## YaFFS2

*Yet Another Flash FileSystem*

YaFFS2 may use the 'YA\xffS' signature

YaFFS2 uses fixed size blocks

Depends on OOB data, so use a dump from `nanddump -o`

OOB data format may vary, use `hexinspect mydump 2048 64` to manually inspect and adapt `parse_oob()`

OOB data used to store YaFFS block metadata
* object\_id = file/inode identifier
* chunk\_id = data offset where the data in this block fits inside the file
* block\_seq = block version information
  * higher value supersedes lower value for a given objid+chkid
  * same value supersedes earlier instance in the same flash erase block

chunk\_id 0 holds file metadata
* file name
* file size
* object\_id of parent directory
* mtime

File deletion: rename file to 'deleted' or 'unlinked' and change parent directory id to 3 or 4


## Script usage

`ruby yaffs2.rb mtd0`
List all objects / filenames

`ruby yaffs.rb mtd0 42`
Dump object with id 42 in `objid_42_<filename>`
* Output all versions of file data from chunk history
* `log` file has debug info, incl metadata

`ruby yaffs.rb mtd0 -a`
Dump all objects

`ruby yaffs.rb mtd0 -r`
Rebuild a filesystem hierarchy from a previous `-a` full dump under `root/`

