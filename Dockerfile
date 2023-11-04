# syntax=docker/dockerfile:1
# docker buildx create --use --name insecure-builder --buildkitd-flags '--allow-insecure-entitlement security.insecure'
# docker buildx build --output type=docker --build-arg UNAMEM=$(uname -m) -t mylfs:latest .
# docker buildx build --allow security.insecure --output type=docker --build-arg UNAMEM=$(uname -m) -t mylfs:latest .

FROM ubuntu as chapter4to7
# for debug: docker build --target chapter4to7 -t prelfs .

ENV LFS=/mnt/lfs
RUN <<"EOR"
set -e
apt update
apt install -y sudo git wget python3 mg
mkdir /alfs
cd /alfs
git clone --branch 12.0 https://git.linuxfromscratch.org/lfs.git lfs-git
ln -svf /bin/bash /bin/sh
apt install -y build-essential bison gawk patch texinfo
mkdir -pv $LFS
mkdir -v $LFS/sources
chmod -v a+wt $LFS/sources
EOR

# Get source files
RUN <<"EOR"
set -e
wget https://www.linuxfromscratch.org/lfs/view/stable/wget-list-sysv
wget --input-file=wget-list-sysv --continue --directory-prefix=$LFS/sources
wget --directory-prefix=$LFS/sources https://www.linuxfromscratch.org/lfs/view/stable/md5sums
cd $LFS/sources && md5sum -c md5sums
# chown root:root $LFS/sources/*
EOR

# Chapter 4: final preparations
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

# CLI
parser = argparse.ArgumentParser()
parser.add_argument(
    '--resume-from',
    help='Starts building from this package, e.g. "binutils-pass1"'
)
parser.add_argument('--chroot', action='store_true')
parser.add_argument('chapter', help='Chapters to build, e.g. "06 07"', nargs='+')
args = parser.parse_args()

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

#pkgname_exceptions = {
#    'binutils-pass1': 'binutils',
#    'gcc-libstdc++': 'gcc',
#    'gcc-pass1': 'gcc',
#    'linux-headers': 'linux',
#    'binutils-pass2': 'binutils',
#    'gcc-pass2': 'gcc'
#}

resume = True if args.resume_from else False
for chapter in args.chapter:
    print('Compiling for chapter', chapter)
    chroot = args.chroot and int(chapter)>=7
    tree = ET.parse(f"/alfs/lfs-git/chapter{chapter}/chapter{chapter}.xml")
    root = tree.getroot()
    for child in root:
        if child.tag == 'title': continue
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
        if not info:
            continue
        ET.dump(info)
        pkgname = info.find('productname').text
        if resume:
            if args.resume_from == pkgname:
                resume = False
            else: continue
        #pkgname = pkgname_exceptions.get(pkgname, pkgname)
        pkgversion = info.find('productnumber').text
        pkgfile = info.find('address').text.strip()
	pkgfile = pkgfile[pkgfile.rindex('/')+1:]
	pkgdir = pkgfile[:-7]
        pkgext = pkgfile[-7:]
        tempscript = tempfile.NamedTemporaryFile(
            suffix=f"c{chapter}.sh", delete=False,
            prefix='/mnt/lfs/tmp/' if chroot else None
        )
        with open(tempscript.name, 'wt') as shout:
            shout.writelines([
                '#!/bin/bash\n',
                'set -e\n',
                'cd $LFS/sources\n',
                f"tar -xvf {pkgfile}\n",
                f"cd {pkgdir}\n"
            ])
            for ui in component_root.findall('.//screen/userinput'):
                shout.write(ui.text+'\n')
            shout.writelines([
                'cd $LFS/sources\n','env\n',
                f"rm -rf {pkgdir}\n"
            ])
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
            exit(0)
        tempscript.close()
EOF
#SHELL ["/bin/bash", "-c"]
RUN python3 /alfs/pylfs.py 05 06

# Chapter 7
FROM scratch as chapter7
COPY --from=chapter4to7 /mnt/lfs /
COPY --from=chapter4to7 /alfs /alfs
# Create /etc/passwd
COPY <<"EOF" /etc/passwd
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

# Create /etc/group
COPY <<"EOF" /etc/group
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
usb:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

RUN <<"EOR"
set -e
chown -R root:root $LFS/{usr,lib,var,bin,sbin,tools}
#to include etc needs to run with privilige
#chown -R root:root $LFS/{usr,lib,var,etc,bin,sbin,tools}
case $(uname -m) in
  x86_64) chown -R root:root $LFS/lib64 ;;
esac
# Steps not necesarry in docker context
#mkdir -pv $LFS/{dev,proc,sys,run}
#mount -v --bind /dev $LFS/dev
#mount -v --bind /dev/pts $LFS/dev/pts
#mount -vt proc proc $LFS/proc
#mount -vt sysfs sysfs $LFS/sys
#mount -vt tmpfs tmpfs $LFS/run
#if [ -h $LFS/dev/shm ]; then
#  mkdir -pv $LFS/$(readlink $LFS/dev/shm)
#else
#  mount -t tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
#fi
#chroot "$LFS" /usr/bin/env -i   \
#    HOME=/root                  \
#    TERM="$TERM"                \
#    PS1='(lfs chroot) \u:\w\$ ' \
#    PATH=/usr/bin:/usr/sbin     \
#    /bin/bash --login
mkdir -pv /{boot,home,mnt,opt,srv}
mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{include,src}
mkdir -pv /usr/local/{bin,lib,sbin}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}

ln -sfv /run /var/run
ln -sfv /run/lock /var/lock

install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp

#ln -sv /proc/self/mounts /etc/mtab
# needs privilige to overwrite /etc/hosts
#cat > /etc/hosts << EOF
#127.0.0.1  localhost $(hostname)
#::1        localhost
#EOF

# Test account
echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
echo "tester:x:101:" >> /etc/group
install -o tester -d /home/tester
#exec /usr/bin/bash --login
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664  /var/log/lastlog
chmod -v 600  /var/log/btmp

# Install python3 to run pylfs script
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
EOR

# Chapter 7 packages
RUN python3 /alfs/pylfs.py 07

# Cleaning up
RUN <<"EOR"
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name \*.la -delete
rm -rf /tools
EOR

FROM scratch
COPY --from=chapter7 / /
#mv tcl src to tcl for issue
RUN python3 /alfs/pylfs.py 08
