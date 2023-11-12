# syntax=docker/dockerfile:1
# docker buildx use --default default
# docker buildx build --output type=docker --build-arg UNAMEM=$(uname -m) -t mylfs:latest .
# docker buildx create --use --name insecure-builder --buildkitd-flags '--allow-insecure-entitlement security.insecure'
# docker buildx build --allow security.insecure --output type=docker --build-arg UNAMEM=$(uname -m) -t mylfs:latest .

FROM ubuntu as chapter3to6
# for debug: docker build --target chapter3to6 -t prelfs .

ARG LFSVERSION=12.0
ENV LFS=/mnt/lfs

# Chapter 3. Packages and Patches
RUN <<"EOR"
set -e
apt update
apt install -y sudo git wget python3 mg
mkdir /alfs
cd /alfs
git clone --branch $LFSVERSION https://git.linuxfromscratch.org/lfs.git lfs-git
git clone --branch $LFSVERSION https://git.linuxfromscratch.org/blfs.git blfs-git
ln -svf /bin/bash /bin/sh
apt install -y build-essential bison gawk patch texinfo
mkdir -pv $LFS
mkdir -v $LFS/sources
chmod -v a+wt $LFS/sources

# Get source files
wget https://www.linuxfromscratch.org/lfs/view/$LFSVERSION/wget-list-sysv
wget --input-file=wget-list-sysv --continue --directory-prefix=$LFS/sources
wget --directory-prefix=$LFS/sources https://www.linuxfromscratch.org/lfs/view/stable/md5sums
cd $LFS/sources && md5sum -c md5sums
# chown root:root $LFS/sources/* # already root
EOR

# Chapter 4. Final Preparations
RUN <<"EOR"
set -e
mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib,sbin}
for i in bin lib sbin; do ln -sv usr/$i $LFS/$i; done
case $(uname -m) in x86_64) mkdir -pv $LFS/lib64 ;; esac
mkdir -pv $LFS/tools
groupadd lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs
chown -v lfs $LFS/{usr{,/*},lib,var,etc,bin,sbin,tools}
case $(uname -m) in  x86_64) chown -v lfs $LFS/lib64 ;; esac
[ ! -e /etc/bash.bashrc ] || mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE
EOR

# in lfs handbook: su - lfs
USER lfs
WORKDIR /home/lfs
# https://docs.docker.com/engine/reference/builder/#here-documents
RUN <<"EOT" bash
cat > ~/.bash_profile << "EOF"
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF
EOT

COPY <<"EOF" /home/lfs/.bashrc
set +h
umask 022
LFS=/mnt/lfs
LC_ALL=POSIX
LFS_TGT=$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export MAKEFLAGS='-j4' # multiprocess build (optional)
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
EOF
# source ~/.bash_profile # should not be necessary in Dockerfile context
# In Dockerfile context same variables neet to be explicitly set
ENV LC_ALL=POSIX
ARG UNAMEM
ENV LFS_TGT=${UNAMEM}-lfs-linux-gnu
ENV PATH=${LFS}/tools/bin:/usr/bin
ENV CONFIG_SITE=${LFS}/usr/share/config.site

# Part III Building the LFS Cross Toolchain
WORKDIR /mnt/lfs/sources
COPY <<"EOF" /alfs/pylfs.py
import os
import re
import argparse
import tempfile
import xml.etree.ElementTree as ET
import subprocess as sp

# Read entities
entity_regex = re.compile(r'<!ENTITY(?: \%)? ([\w-]+)\s+(?:\w+\s+)?"(.*)">')
entities = []
for entfile in ('general', 'packages', 'patches'):
    with open(f"/alfs/lfs-git/{entfile}.ent") as ef:
        for line in ef:
            if line.startswith('<!ENTITY'):
                try: entities.append(
                    entity_regex.match(line).groups()
                )
                except AttributeError:
                    print(entity_regex,line)
                    raise
entities = dict(entities)
entity_repl_regex = re.compile(r'&[\w-]+;')
def expand_entities(entity_value):
    for entity in set(entity_repl_regex.findall(entity_value)):
        entity_value = entity_value.replace(entity,expand_entities(entities.get(entity[1:-1], 'NA')))
    return entity_value
for e in list(entities):
    entities[e] = expand_entities(entities[e])
# Other entity issues
entities['mdash'] = '-'
entities['ndash'] = '-'
# tcl chapter 8
entities['tdbc-ver'] = '1.1.5'
entities['itcl-ver'] = '4.2.3'
# clock chapter 9
entities['AElig'] = ''
entities['site'] = 'local'
entities['nbsp'] = ' '

pkgname_exceptions = {
    'binutils-pass1': 'binutils',
    'gcc-libstdc++': 'gcc',
    'gcc-pass1': 'gcc',
    'linux-headers': 'linux',
    'binutils-pass2': 'binutils',
    'gcc-pass2': 'gcc'
}
# Command modification to enable autobuild
# Packages with known test failures still execute step but continue
mct = ('make check','make check || true')
mkct = ('make -k check','make -k check || true')
command_mods = {
    # format: (chapter, package): [(oldcommand, replacement),]
    ('07','ch-tools-createfiles'): [
      # This should be conditional for (unpriviliged) build step
      ('ln -sv /proc/self/mounts /etc/mtab',''),
      ('cat > /etc/hosts << EOF','cat > /tmp/hosts << EOF')
    ],
    ('07','ch-tools-changingowner'): [(',etc,',',')],
    ('08','glibc'): [mct],
    ('08','binutils'): [mkct],
    ('08','attr'): [mct], # might be docker filesystem
    ('08','shadow'): [('passwd root','')], # asks for 'root' password interactively
    ('08','libtool'): [mkct],
    ('08','inetutils'): [mct], # failed hostname -> controlled by docker
    ('08','automake'): [('make -j4 check','make -j4 check || true')],
    ('08','coreutils'): [
      # test-getlogin can fail
      ('su tester -c "PATH=$PATH make RUN_EXPENSIVE_TESTS=yes check"',
      'su tester -c "PATH=$PATH make RUN_EXPENSIVE_TESTS=yes check" || true')],
    ('08','tar'): [mct], ('08','man-db'): [mkct],
    ('08','vim'): [
      ('su tester -c "LANG=en_US.UTF-8 make -j1 test" &> vim-test.log',
      'su tester -c "LANG=en_US.UTF-8 make -j1 test" &> vim-test.log || true'),
      ("vim -c ':options'",'')],
    ('08','util-linux'): [('su tester -c "make -k check"','su tester -c "make -k check" || true')],
    ('08','bash'): [
      ('exec /usr/bin/bash --login',''),
      ('tests/run.sh --srcdir=$PWD --builddir=$PWD','')],
    ('08','procps-ng'):[mct],
    ('08','ch-system-stripping'):[(
      ') strip --strip-unneeded $i',
      ') strip --strip-unneeded $i || true')]
}
replaceables = {
  '<paper_size>':'A4',
  '<xxx>': 'en_GB' # zoneinfo
}

def download_file(url, dir):
    import ssl
    #See python note in https://www.linuxfromscratch.org/blfs/view/svn/postlfs/make-ca.html
    import certifi
    from urllib.request import urlopen
    context = ssl.create_default_context(cafile=certifi.where())
    with open(os.path.join(dir,url.split('/')[-1]),'wb') as out:
        out.write(urlopen(url,context=context).read())

def process_chapter(chapter, chroot, resume_from=None,
    install_packages=None, skip_packages={},
    non_package_scripts={}, dry_run=False):
    resume = True if resume_from else False
    tree = ET.parse(f"/alfs/lfs-git/chapter{chapter}/chapter{chapter}.xml")
    root = tree.getroot()
    print(root[0].text) # root[0].tag == 'title'
    for child in root[1:]:
        component_file = os.path.join(
            f"/alfs/lfs-git/chapter{chapter}/",
            child.attrib['href']
        )
        parser = ET.XMLParser() #ET.XMLPullParser(['start', 'end'])
        #parser.parser.UseForeignDTD(True)
        parser.entity.update(entities)
        component_tree = ET.parse(component_file, parser=parser)
        component_root = component_tree.getroot()
        info = component_root.find('sect1info')
        if info:
            pkgname = info.find('productname').text
            if resume:
                if resume_from == pkgname:
                    resume = False
                else: continue
            elif install_packages and pkgname not in install_packages:
                continue
            elif pkgname in skip_packages: continue
            ET.dump(info)
        
            pkgname = pkgname_exceptions.get(pkgname, pkgname)
            pkgversion = info.find('productnumber').text
            pkgfile = info.find('address').text.strip()
            pkgfile = pkgfile[pkgfile.rindex('/')+1:]
            pkgdir = pkgfile[:pkgfile.rindex('.tar.')]
            pkgext = pkgfile[pkgfile.rindex('.tar.'):]
        elif component_root.get('id') in non_package_scripts:
            pkgname = component_root.get('id')
        else:
            print(component_root.get('id'))
            continue
        
        tempscript = tempfile.NamedTemporaryFile(
            suffix=f"c{chapter}.sh", delete=False,
            prefix='/mnt/lfs/tmp/' if chroot else None
        )
        with open(tempscript.name, 'wt') as shout:
            shout.writelines([
                '#!/bin/bash\n',
                'set -e\n',
                'cd $LFS/sources\n',
            ])
            if info: shout.writelines([
                f"tar -xvf {pkgfile}\n",
                f"cd {pkgdir}\n"
            ])
            nodumps = set(
                component_root.findall(
                    './/screen[@role="nodump"]/userinput'
            ))
            for ui in component_root.findall('.//screen/userinput'):
                if ui.text and ui not in nodumps:
                    scriptext = ui.text
                    for literal in ui.findall('literal'):
                        # Probably only ever 1 literal
                        scriptext += literal.text + literal.tail
                    for replace in ui.findall('replaceable'):
                        # A mix of literal and replaceable will break the code
                        scriptext += replaceables[replace.text] + replace.tail
                    if (chapter, pkgname) in command_mods:
                        for mod in command_mods[(chapter, pkgname)]:
                            scriptext = scriptext.replace(mod[0],mod[1])
                    shout.write(scriptext+'\n')
            if info: shout.writelines([
                'cd $LFS/sources\n',
                f"rm -rf {pkgdir}\n"
            ])
        if dry_run:
            print(open(tempscript.name).read())
            input()
        else:
            spout = sp.run(
                ["bash", tempscript.name] if not chroot
                else [
                    'chroot', os.environ['LFS'], '/usr/bin/env', '-i',
                    'HOME=/root', f'TERM="{os.environ["TERM"]}"',
                    "PS1='(lfs chroot) \\u:\\w\\$ '",
                    'PATH=/usr/bin:/usr/sbin',
                    '/bin/bash', #'--login',
                    tempscript.name[8:]
                ], capture_output=True
            )
            #print(spout.stdout)
            print(spout.stderr[-500:])
            #spout.check_returncode()
            if spout.returncode != 0:
                print(spout.stdout[-500:])
                with open('failed_log.txt', 'wb') as f:
                    f.write(spout.stdout[-500:])
                    f.write(spout.stderr[-500:])
                exit(1)
        tempscript.close()
        last_processed = component_root
    return component_root

if __name__ == '__main__':
    # CLI
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--resume-from',
        help='Starts building from this package, e.g. "binutils-pass1"'
    )
    parser.add_argument(
      '--install-package', action='append',
      help='Instead of installing all chapter packages, just this/these'
    )
    parser.add_argument(
      '--skip-package', action='append',
      help='Skip installation of this package'
    )
    parser.add_argument(
      '--script-section', action='append',
      help='Provide section id for non-package script section'
    )
    parser.add_argument('--chroot', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('chapter', help='Chapters to build, e.g. "06 07"', nargs='+')
    args = parser.parse_args()
    resume_from = args.resume_from
    skip_packages = args.skip_package or []
    non_package_scripts = args.script_section or []

    for chapter in args.chapter:
        print('Compiling for chapter', chapter)
        chroot = args.chroot and int(chapter)>=7
        process_chapter(
            chapter, chroot=chroot, resume_from=resume_from,
            install_packages=args.install_package,
            skip_packages=skip_packages,
            non_package_scripts=non_package_scripts,
            dry_run=args.dry_run
        )
        resume=False # only for first chapter being processed

EOF
RUN python3 /alfs/pylfs.py 05 06

# Chapter 7
FROM scratch as chapter7
COPY --from=chapter3to6 /mnt/lfs /
COPY --from=chapter3to6 /alfs /alfs

# Env settings for small build
# https://www.linuxfromscratch.org/hints/downloads/files/small-lfs.txt
ARG CC="gcc -s" CFLAGS="-Os -fomit-frame-pointer" LDFLAGS="-s"

# Minimal /etc/passwd and /etc/group to run initial setup
COPY <<"EOF" /etc/passwd
root:x:0:0:root:/root:/bin/bash
EOF
COPY <<"EOF" /etc/group
root:x:0:
EOF

RUN <<"EOR"
# Install python3 to run pylfs script
mkdir /tmp
cd /sources
PYTHONPACKAGE=$(ls Python-3*.tar.xz)
tar -xvf $PYTHONPACKAGE
cd ${PYTHONPACKAGE%%.tar.xz}
./configure --prefix=/usr \
--enable-shared \
--without-ensurepip
make
make install
cd ..
rm -rf ${PYTHONPACKAGE%%.tar.xz}

python3 /alfs/pylfs.py \
  --script-section ch-tools-changingowner \
  --script-section ch-tools-cleanup \
  --script-section ch-tools-creatingdirs \
  --script-section ch-tools-createfiles \
  07
EOR

FROM scratch
COPY --from=chapter7 / /
RUN <<"EOR"
# tcl package name issue
cd /sources
TCLPACKAGE=$(ls tcl*-src.tar.gz)
ln -s ${TCLPACKAGE%%-src.tar.gz} ${TCLPACKAGE%%.tar.gz}

# Chapter 8 installation
python3 /alfs/pylfs.py --script-section ch-system-stripping \
  --script-section ch-system-cleanup --skip-package dbus \
  08
python3 /alfs/pylfs.py --script-section ch-config-clock \
  --script-section ch-system-inputrc \
  --script-section ch-system-shells \
  --skip-package bootscripts 09
EOR

#RUN <<"EOR"
#cd /sources
#pip3 install requests
#python3 -c"import requests;
#open('wget-1.21.4.tar.gz','wb').write(requests.get('https://ftp.gnu.org/gnu/wget/wget-1.21.4.tar.gz',allow_redirects=True).content)"
#tar -xvf wget-1.21.4.tar.gz
#./configure --prefix=/usr      \
#            --sysconfdir=/etc  \
#            --with-ssl=openssl &&
#make
#make install
#cd ..
#rm -rf wget-1.21.4.tar.gz
#wget --no-check-certificate https://sqlite.org/2023/sqlite-autoconf-3420000.tar.gz
#tar -xvf sqlite-autoconf-3420000.tar.gz
#cd sqlite-autoconf-3420000
#./configure --prefix=/usr     \
#            --disable-static  \
#            --enable-fts{4,5} \
#            CPPFLAGS="-DSQLITE_ENABLE_COLUMN_METADATA=1 \
#                      -DSQLITE_ENABLE_UNLOCK_NOTIFY=1   \
#                      -DSQLITE_ENABLE_DBSTAT_VTAB=1     \
#                      -DSQLITE_SECURE_DELETE=1          \
#                      -DSQLITE_ENABLE_FTS3_TOKENIZER=1"
#make
#make install
#cd ..
#rm -rf sqlite-autoconf-3420000
# python config -> --enable-loadable-sqlite-extensions
#EOR
