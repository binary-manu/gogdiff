# gogdiff.sh: a Bash script that generates self-extracting patches to turn Windows GOG releases into their Linux versions

gogdiff.sh (or simply gogdiff for brevity) is a Bash script that aims at
cutting the storage taken by [GOG][gog] games which support multiple
platforms.

Suppose you buy a game which comes in both Windows and Linux versions.
If you are like me, the main reason you buy from GOG is to have DRM free
offline installers. So you want to download and keep them. And if you
are a Linux gamer, you'd like to keep both versions, with Windows as a
fallback to be run under Wine if the or natively if the Linux versions
has some issues.

GOG releases for different platforms are independent of one another:
each one contains every game file, including non-native files, such as
audio and graphic assets, which are ideally identical between the two
releases. And since these assets make up the largest part of any modern
game, this roughly means doubling the storage needed to store both
installers with respect to keeping just one version.

## What does gogdiff do?

As said, while each platform version obviously ships with a native game
engine and its libraries, game asset files are often:

* byte-by-byte identical between the two, although placed at different
  locations and with different names;
* _slightly different_, meaning that trying to use a binary patch tool
  to generate one from the other results in a very small patch, compared
  to the size of either files.

Game assets tend to fall in either category: some, like the Deponia
series, have identical assets files. An example of the second is Full
Throttle Remastered: the "game" is a single 5GB file, different on Linux
and Windows. But running them through xdelta3 produces a patch files of
about 7MB.

gogdiff tries to exploit this redundancy to create self-extracting patch
scripts, which can be applied against an installation of the Windows
release to generate the Linux release. The idea is for the patch script
to contain only files which are specific to the Linux release, plus
patches which can be used to turn Windows files into their Linux
versions. Files which only belong to Windows are removed, while common
files (those that are identical) are simply renamed.

A user can therefore keep the full Windows edition of the game, plus the
patch script, which is usually _much_ smaller than the full Linux
installer. When she wants to install the game on Linux, she first
installs the Windows version under Wine, then applies the patch script
on top of it. The result is a game directory _identical_ to what the
Linux installer would have produced (barring some minor things such as
desktop entries, which do not affect the game). While this process takes
more time than simply installing the Linux version directly, the space
savings can be significant. As an example, _The Witcher 2_ Linux
installer takes about 20GB, while the patch script is about 260MB (when
applying xz compression, see the `-c` options below).  Running GOG
Windows installers under Wine works fairly well, so it does not pose
compatibility problems. Once the patching is over, you can move the game
folder wherever you want and throw the Wine prefix away.

In details, gogdiff does the following:

* given a Windows GOG installer, it installs the game inside a Wine
  prefix. This step is partially automated, but at the moment user
  interaction is still required to accept the EULA and to click "Next"
  in dependency installers (dotNET, DirectX and others); if the user
  prefers, she can install the game manually and then pass the resulting
  game directory path to gogdiff;
* given a Linux GOG installer, it installs the game inside a temporary
  folder.  This step is fully automated, and takes care of ensuring that
  no desktop entries are created for the game, since these would point
  to the temporary installation; again, the game can be installed
  manually and gogdiff can be pointed to the game directory;
* once both versions are available, gogdiff scans them for files which
  are:
  * common (byte-by-byte identical, but in different places); this is
    done by calculating their MD5s;
  * patchable: files whose Linux versions can be generated from similar
    but not identical Windows versions;
  * belong to Windows only;
  * belong to Linux only;
* finally, it generates a patch script, which is also a Bash script,
  containing the following:
  * instructions to remove Windows-only files;
  * instructions to patch patchable files;
  * instructions to rename common files;
  * instructions to extract Linux-only files, which are appended to the
    end of the script as a compressed tar.

In the current version, patching is done using the `xdelta3` utility.
Also, a file is classified as patchable if its basename appears in both
the Linux and Windows installations, but appears only once within a
single installation. So basically `/path/to/windows/game/foo.dat` and
`/path/to/linux/foo.dat` would be used to create a patch, because their
basenames match. Of course, the assumption here is that the two files
are related, which may not hold true for all games.

The supported options are:

`gogdiff.sh -w <wininst> -l <linuxinst> -o <outdir> [-c <compopts>] [-s <firststep>]`

* `-w` points to either a GOG Windows installer (the `.exe file`) or to
  a pre-installed Windows GOG game. In the latter case, this path should
  be the folder that was specified inside the installer as the
  destination directory, plus the Wine prefix that holds it. For
  example, if a game is installed in Wine prefix
  `/home/user/winegames/mygame` and we typed `C:\mygame` in the
  installer, the path to pass here would be
  `/home/user/winegames/mygame/drive_c/mygame`;
* `-l` expects a Linux GOG installer (usually ending in `.sh`) or a path
  pointing to a pre-installed GOG game. All GOG games have a file called
  `start.sh` in this folder;
* `-o` points to a temporary _state folder_ that will be created if it
  does not exists. It will store all temporary gogdiff data, including
  temporary game installations, MD5 files, patches and the final patch
  script. Be sure to put it on a disk with lots of space (and inodes)!
* `-c` optionally specifies extra options passed to tar to compress the
  tarball with Linux-only files that is appended to the end of the
  script. The default is `-z` (gzip compression) but to save more space
  `--xz` is recommended.
* `-s` defines the step from which to (re)start processing. gogdiff does
  not currently implement tracking which things have already been done,
  so if it gets interrupted before the end, the user must manually
  restart it specifying from which step it need to restart. The
  currently defined steps are (in order of execution): 
  
  * `windows`: install the Windows game, unless a directory is provided
    instead of an executable;
  * `linux`: install the Linux game, unless a directory is provided
    instead of an executable;
  * `digest`: calculate MD5s and create patches for patchable files;
  * `script`: generate the patch script. 
    
  For example, had you managed to install both games, but then the
  `digest` step failed because `xdelta3` was not installed, you can
  install it and restart the operation with an extra `-s digest`. Be
  sure to keep the same value for `-o`!

Some things gogdiff does not currently handle:
* games which use different names for related files, for example
  different extensions on Windows and Linux. These are currently not
  detected as patchable and although it should not be difficult to add
  such a feature, I didn't bother because I got just one game doing this
  so far, and it was small;
* games which use different formats for videos on Windows and Linux: I
  saw a game using H.264 videos on Windows and Motion JPEG on Linux.
  Clearly the two are totally unrelated and given the size of the
  videos, you are better off storing the two installers individually.

## The patch script

If everything goes well, you'll find the patch script inside the state
directory, named `gogdiff_delta.sh`.

In order to apply the patch script on top of a Windows installation, you
need to:

* change the current working directory to the path where the Windows
  game is installed. This is the same path that would have been passed
  to gogdiff using `-w`. There is no options to specify this path: you
  _must_ set it to be the working directory;
* optionally, specify some environment variables that change how the
  patch script operate;
* run the patch script.

The patch script remove Windows-only files, rename common files, extract
Linux-only files and apply patches as needed. After that, it will also
perform an MD5 check, to ensure that all expected files are both present
and correct.

During the patching, temporary directories will be created. Their names
are generated randomly _when the patch script is generated_, not when it
is run. This works because is is expected that the set of subfolders
present in the initial Windows installation will not change, so there is
no need to generate random folders for each execution.  However, this
also means that no extraneous directories should be manually added to a
Windows installation before patching, to avoid a potential clash.

The patch script honors the following environment variables:

* `GOGDIFF_EXTRACTONLY`: if defined to any nonempty value, do not patch
  the game, just extract the tar at the end of the script in the current
  working directory;
* `GOGDIFF_NOSYMLINKS`: by default, if a Linux game contains multiple
  copies of the same file, only one file is actually created; the others
  are replaced by symlinks to save space. Setting this variable to any
  nonempty value reverts the behaviour so that multiple regular files
  are created;
* `GOGDIFF_SKIPDIGESTS`: if set to any nonempty value, post-patching
  digest checks are skipped;
* `GOGDIFF_VERBOSE`, if set to any nonempty value, verbosely log all
  operations done (file rename, copy, patching). By default no output is
  produced while patching, unless an error occurs.

## Layout of the state folder

The state directory specified with the `-o` option can contain the
following items:

* `digests/`: stores file digests, as well as the files that track
  common, Linux-only and Windows-only files;
* `delta/`: used to track files with identical basenames across game
  installations;
* `patches/`: stores patches created by xdelta3;
* `windows/`: if `-w` specifies a game installer, this directory holds
  the Wine prefix where the game is installed. The game will usually be
  installed under this directory at subpath `drive_c/goggame`;
* `linux/`: if `-l` specifies a game installer, this directory will
  contain the installed game;
* `junk/`: used as a place were installers should place things we want
  to throw away, like desktop entries.
* `gogdiff_delta.sh`: the patch script.
  
Some directories, notably `windows`, `linux` and `delta` can grow to
contains tens of thousands of files (I've seen games with over 50000
files).

## Test suite

There is a crude test suite under `test`. Each test sits in a dedicated
folder named like `0001` (four decimal digits). The file `run.bash` will
run all tests and log their results to `test.log`. There is currently no
way to selectively run tests.

Each test folder contains:
* a `windows` folder, containing the fake Windows game installation used
  for the test;
* a `linux` folder, containing the fake Linux game installation used for
  the test;
* an `exit` file, containing the expected exit code from gogdiff on a
  line by itself;
* an optional, empty `no_delta` file whose presence instructs the test
  driver that it is OK for a test not to produce a patch script;
* `README.txt` contains a one-line description of the test, Grep them
  all to have an overview of the available tests.

## Dependencies

Both gogdiff and patch scripts require:

* The Bash shell at version 4 or higher;
* the `xdelta3` tool;
* GNU coreutils, GNU findutils, GNU sed, GNU tar;
* some other ubiquitous command line tools.

I've tested this script on my GOG collection of Linux titles (about 40)
and it worked on all of them but a couple, whose Windows and Linux
versions were too different to allow for any commonality to be
exploited. Testing was done on Arch Linux.


[gog]: https://www.gog.com/

<!-- vi: set tw=72 et sw=2 fo=tcroqan autoindent: -->
