#!/bin/bash
# This file is hosted at:
#  http://code.google.com/p/maemo-sdk-image/
#
# This file is based on:
#  http://developer.amazonwebservices.com/connect/message.jspa?messageID=42535#42535
#  http://blog.atlantistech.com/index.php/2006/10/04/amazon-elastic-compute-cloud-walkthrough/
#  http://developer.amazonwebservices.com/connect/entry.jspa?categoryID=116&externalID=661
#  http://overstimulate.com/articles/2006/08/24/amazon-does-it-again.html
#  http://www.howtoforge.com/amazon_elastic_compute_cloud_qemu
#  http://info.rightscale.com/2007/2/14/bundling-up-an-ubuntu-ec2-instance
#  http://repository.maemo.org/stable/3.1/INSTALL.txt

# Need to get settings for
#  EC2_HOME
#  EC2_PRIVATE_KEY
#  EC2_CERT
#  EC2_ID
#  AWS_ID
#  AWS_PASSWORD
#  PATH -- must include EC2_HOME/bin
#  S3_BUCKET
source ./secret/setup_env.sh

# Additional parameters for initiating host
if [ -e $EC2_HOME/bin/ec2-describe-instances ];
then
 ec2-describe-instances | tee maemo-ami-instances.txt;
 perl -ne '/^INSTANCE\s+(\S+)\s+\S+\s+(\S+)\s+\S+\s+running\s+maemo-ami-keypair\s+/ && print "$1";' maemo-ami-instances.txt > maemo-ami-instance.txt;
 perl -ne '/^INSTANCE\s+(\S+)\s+\S+\s+(\S+)\s+\S+\s+running\s+maemo-ami-keypair\s+/ && print "$2";' maemo-ami-instances.txt > maemo-ami-mach-name.txt;
 EC2_INSTANCE=`cat maemo-ami-instance.txt`;
 EC2_MACH_NAME=`cat maemo-ami-mach-name.txt`;
 echo EC2_MACH_NAME=$EC2_MACH_NAME;
 echo EC2_INSTANCE=$EC2_INSTANCE;

 BASE_AMI=ami-20b65349;
 FEISTY_AMI=`perl -ne '/^IMAGE\s+(\S+)/ && print "$1";' ubuntu-ami-image.txt`;
 FEISTY2_AMI=`perl -ne '/^IMAGE\s+(\S+)/ && print "$1";' ubuntu-patched-ami-image.txt`;
fi 

function make-keypair {
ec2-delete-keypair maemo-ami-keypair
ec2-add-keypair maemo-ami-keypair > maemo-ami-keypair.txt
chmod 600 maemo-ami-keypair.txt
}

function run-default-ami {
run-ami $DEFAULT_AMI
}

function run-ami {
AMI=$1
ec2-run-instances $AMI -k maemo-ami-keypair

echo > maemo-ami-instances.txt
while
 perl -ne '/^INSTANCE\s+(\S+)\s+\S+\s+(\S+)\s+\S+\s+running\s+maemo-ami-keypair\s+/ && print "$1";' maemo-ami-instances.txt > maemo-ami-instance.txt;
 perl -ne '/^INSTANCE\s+(\S+)\s+\S+\s+(\S+)\s+\S+\s+running\s+maemo-ami-keypair\s+/ && print "$2";' maemo-ami-instances.txt > maemo-ami-mach-name.txt;
 perl -ne '/^INSTANCE\s+(\S+)\s+\S+\s+(\S+)\s+\S+\s+running\s+maemo-ami-keypair\s+/ && exit(1);' maemo-ami-instances.txt
do
 ec2-describe-instances | tee maemo-ami-instances.txt;
done
}

function authorize-ssh {
ec2-authorize default -p 22
}

function create-ubuntu-image {
##
## This portion runs on FC4 and creates a base Ubuntu image
##
set -e

# Set up a filesystem image
dd if=/dev/zero of=/mnt/ubuntu704base.img bs=1M count=4096
mkfs.ext3 -F -j -m 0 /mnt/ubuntu704base.img

mkdir /ubuntu
mount /mnt/ubuntu704base.img /ubuntu -o loop

# Install debootstrap to enable us to install a minimal Ubuntu system. This will
# splatter files all over /usr, but since this instance is transient, I don't
# think it matters.
cd /tmp
#wget http://mirrors.kernel.org/ubuntu/pool/main/d/debootstrap/debootstrap_0.3.3.0ubuntu7_all.deb
#ar -p debootstrap_0.3.3.0ubuntu7_all.deb data.tar.gz |tar -zxC /
wget http://mirrors.kernel.org/ubuntu/pool/main/d/debootstrap/debootstrap_1.0.1~feisty1_all.deb
ar -p debootstrap_1.0.1~feisty1_all.deb data.tar.gz |tar -zxC /

debootstrap --arch i386 feisty /ubuntu http://mirrors.kernel.org/ubuntu

# Here we write a script that is to be executed in the context of the new
# Ubuntu filesystem using chroot.
cat <<EOCHROOT >/ubuntu/install-script
#!/bin/bash
cat <<EOF >/etc/apt/sources.list
deb http://mirrors.kernel.org/ubuntu feisty main restricted universe multiverse
deb-src http://mirrors.kernel.org/ubuntu feisty main restricted universe multiverse

deb http://mirrors.kernel.org/ubuntu feisty-updates main restricted universe multiverse
deb-src http://mirrors.kernel.org/ubuntu feisty-updates main restricted universe multiverse

deb http://security.ubuntu.com/ubuntu feisty-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu feisty-security main restricted universe multiverse

EOF

localedef -i en_US -c -f UTF-8 en_US.UTF-8
echo "US/Central" >/etc/timezone
ln -s /usr/share/zoneinfo/US/Central /etc/localtime

# Set up the essential EC2 disk and network settings
cat <<EOF >/etc/fstab
/dev/sda2	/mnt	ext3	defaults	1	2
/dev/sda3	swap	swap	defaults	0	0
EOF

cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# When you use the -k argument to ec2run, the ssh key file is installed on the
# instance as /mnt/openssh_id.pub. This rc.local copies it over to the root
# account so that you can actually use it to login. The code is just copied
# verbatim from one of the pre-made EC2 images.

cat <<EOF >/etc/rc.local
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.

# Fetch any credentials present in the ephemeral store:
if [ ! -d /root/.ssh ] ; then
	mkdir -p /root/.ssh
	chmod 700 /root/.ssh
fi

# Fetch ssh key for root
wget http://169.254.169.254/2007-01-19/meta-data/public-keys/0/openssh-key
mv -f openssh-key /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

exit 0
EOF

apt-get update
apt-get -y upgrade

# Need the EC2 kernel modules
#  http://developer.amazonwebservices.com/connect/thread.jspa?messageID=44025&#44025
#  http://developer.amazonwebservices.com/connect/thread.jspa?messageID=46860&#46860

apt-get -y install wget

cd /root

wget http://s3.amazonaws.com/ec2-downloads/modules-2.6.16-ec2.tgz
tar -C / -zxf modules-2.6.16-ec2.tgz
rm -f modules-2.6.16-ec2.tgz
depmod -a

# Enable shadow passwords for SSH's sake
shadowconfig on

# Disable the root password
passwd -d root
passwd -l root

# Install SSH
# I know this looks moderately insane, but it works. The installation fails
# because it can't start the service. Then the removal fails before it can't
# stop the service, and since the removal fails dpkg concludes that the
# package is already installed. We try installing it again just to confirm that.
set +e
apt-get -y install openssh-server
apt-get -y remove openssh-server
set -e
apt-get -y install openssh-server

apt-get clean

EOCHROOT

chroot /ubuntu /bin/bash /install-script
rm -f /ubuntu/install-script

umount /ubuntu
}

function patch-ubuntu {
set -e
apt-get update

# These are needed by the EC2 scripts
apt-get -y install ruby libopenssl-ruby rsync alien openssl curl

# These are needed to use the EC2 scripts on Ubuntu
apt-get -y install patch alien

# These are just helpful
apt-get -y install man

cd /root
wget http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools.noarch.rpm
alien --to-deb ec2-ami-tools.noarch.rpm
#apt-get -y autoremove --perge alien
dpkg -i ec2-ami-tools_*.deb
rm -f ec2-ami-tools*

# FC and Ubuntu keep their local Ruby libraries in different places.
# As mentioned here:
#  http://developer.amazonwebservices.com/connect/thread.jspa?messageID=47005&#47005

ln -s /usr/lib/site_ruby/aes /usr/local/lib/site_ruby/1.8/aes

# We need to patch several of the EC2 scripts. This is just because Ubuntu isn't
# supported at this point in the beta.
#
# One has to do with an assumption about FC which isn't valid on Ubuntu:
#  http://developer.amazonwebservices.com/connect/thread.jspa?messageID=48238&#48238
#
# Another is because the script assumes that /bin/sh will be bash, and on Ubuntu
# it is dash instead:
#  http://solutions.amazonwebservices.com/connect/message.jspa?messageID=47004
#  http://developer.amazonwebservices.com/connect/thread.jspa?threadID=12491&tstart=0

cd /usr/lib/site_ruby/aes/amiutil
cat <<EOF |patch -p0
diff -ru /tmp/amiutil.orig/bundle.rb /usr/lib/site_ruby/aes/amiutil/bundle.rb
--- /tmp/amiutil.orig/bundle.rb	2006-11-18 07:57:07.000000000 -0500
+++ /usr/lib/site_ruby/aes/amiutil/bundle.rb	2006-11-24 03:58:20.000000000 -0500
@@ -54,11 +54,11 @@
         # Cat the file and tee it to the digest process and to the 
         # tar, gzip and encryption process pipeline.
         pipe_cmd = 
-          "tar -chS -C #{File::dirname( image_file )} #{File::basename( image_file )} | \\
+          "/bin/bash -c 'tar -chS -C #{File::dirname( image_file )} #{File::basename( image_file )} | \\
            tee #{PIPE1} |gzip | \\
            openssl enc -e -aes-128-cbc -K #{key} -iv #{iv} > \\
            #{bundled_file_path}; \\
-           for i in \${PIPESTATUS[@]}; do [ \$i == 0 ] || exit \$i; done"
+           for i in \${PIPESTATUS[@]}; do [ \$i == 0 ] || exit \$i; done'"
         unless system( pipe_cmd ) and \$?.exitstatus == 0
           raise "error executing #{pipe_cmd}, exit status code #{\$?.exitstatus}"
         end
diff -ru /tmp/amiutil.orig/bundlevol.rb /usr/lib/site_ruby/aes/amiutil/bundlevol.rb
--- /tmp/amiutil.orig/bundlevol.rb	2006-11-18 07:57:07.000000000 -0500
+++ /usr/lib/site_ruby/aes/amiutil/bundlevol.rb	2006-11-24 03:57:16.000000000 -0500
@@ -82,7 +82,7 @@
 TEXT
 
 ALWAYS_EXCLUDED = ['/dev', '/media', '/mnt', '/proc', '/sys']
-LOCAL_FS_TYPES = ['ext2', 'ext3', 'xfs', 'jfs', 'reiserfs']
+LOCAL_FS_TYPES = ['ext2', 'ext3', 'xfs', 'jfs', 'reiserfs', 'tmpfs']
 MAX_SIZE_MB = 10 * 1024  # 10 GB in MB
 MTAB_PATH = '/etc/mtab'
 DEBUGON = 'on'
diff -ru /tmp/amiutil.orig/image.rb /usr/lib/site_ruby/aes/amiutil/image.rb
--- /tmp/amiutil.orig/image.rb	2006-11-18 07:57:07.000000000 -0500
+++ /usr/lib/site_ruby/aes/amiutil/image.rb	2006-11-24 03:56:42.000000000 -0500
@@ -146,7 +146,7 @@
     # Make device nodes.
     dev_dir = IMG_MNT + '/dev'
     Dir.mkdir( dev_dir )
-    exec( 'for i in console null zero ; do /sbin/MAKEDEV -d ' + dev_dir + ' -x \$i ; done' )
+    exec( "cd #{dev_dir} && /sbin/MAKEDEV console && /sbin/MAKEDEV std && /sbin/MAKEDEV generic" )
   end
 
   #----------------------------------------------------------------------------#
EOF

apt-get clean
}

function bundle-vol {
IMAGE_NAME=$1
echo IMAGE_NAME=$IMAGE_NAME
ec2-bundle-vol -d /mnt -e /root/secret -k /root/secret/pk.pem -c /root/secret/cert.pem -u $EC2_ID -p $IMAGE_NAME
ec2-upload-bundle -b $S3_BUCKET -m /mnt/$IMAGE_NAME.manifest.xml -a $AWS_ID -s $AWS_PASSWORD
}

function remote {
copy-files

ssh -i maemo-ami-keypair.txt root@$EC2_MACH_NAME /root/build_maemo_ami.sh $1 $2 $3 $4 $5 $6 $7 $8 $9
}

function copy-files {
chmod 700 build_maemo_ami.sh

ssh -i maemo-ami-keypair.txt root@$EC2_MACH_NAME "mkdir /root/secret; chmod 700 /root/secret"
scp -i maemo-ami-keypair.txt $EC2_CERT root@$EC2_MACH_NAME:/root/secret/cert.pem
scp -i maemo-ami-keypair.txt $EC2_PRIVATE_KEY root@$EC2_MACH_NAME:/root/secret/pk.pem
scp -i maemo-ami-keypair.txt secret/setup_env.sh root@$EC2_MACH_NAME:/root/secret/setup_env.sh
scp -i maemo-ami-keypair.txt build_maemo_ami.sh root@$EC2_MACH_NAME:/root/build_maemo_ami.sh
}

function halt-ami {
#AMI=$1
ec2-describe-instances | tee maemo-ami-instances.txt;
perl -ne '/^INSTANCE\s+(\S+)\s+\S+\s+(\S+)\s+\S+\s+running\s+maemo-ami-keypair\s+/ && print "$1";' maemo-ami-instances.txt > maemo-ami-instance.txt;
perl -ne '/^INSTANCE\s+(\S+)\s+\S+\s+(\S+)\s+\S+\s+running\s+maemo-ami-keypair\s+/ && print "$2";' maemo-ami-instances.txt > maemo-ami-mach-name.txt;
EC2_INSTANCE=`cat maemo-ami-instance.txt`;
EC2_MACH_NAME=`cat maemo-ami-mach-name.txt`;
ec2-terminate-instances $EC2_INSTANCE;
}

function login-ami {
ssh -i maemo-ami-keypair.txt root@$EC2_MACH_NAME
}

function publish {
ec2-register $S3_BUCKET/$1.manifest.xml
}

function scratchbox {
adduser sbuser --disabled-password --system
wget http://repository.maemo.org/stable/3.1/maemo-scratchbox-install_3.1.sh
chmod a+x ./maemo-scratchbox-install_3.1.sh
./maemo-scratchbox-install_3.1.sh -s /scratchbox -d -u sbuser
}

function bundle-image {
ec2-bundle-image -i /mnt/$1 -k ~root/secret/pk.pem -c ~root/secret/cert.pem -u $EC2_ID
ec2-upload-bundle -b $S3_BUCKET -m /mnt/$1.manifest.xml -a $AWS_ID -s $AWS_PASSWORD
}

function maemo-sdk {
wget http://repository.maemo.org/stable/3.1/maemo-sdk-install_3.1.sh
chmod a+x ./maemo-sdk-install_3.1.sh
#./maemo-sdk-install_3.1.sh -y
sudo -u sbuser bash maemo-sdk-install_3.1.sh
# Need to add some acceptance of Nokia EUSA
sudo -u sbuser /scratchbox/login sb-conf select SDK_X86
sudo -u sbuser /scratchbox/login fakeroot apt-get -y install maemo-explicit
sudo -u sbuser /scratchbox/login sb-conf select SDK_ARMEL
sudo -u sbuser /scratchbox/login fakeroot apt-get -y install maemo-explicit
sudo -u sbuser /scratchbox/login apt-get update
sudo -u sbuser /scratchbox/login fakeroot apt-get -f install
sudo -u sbuser /scratchbox/login sb-conf select SDK_X86
sudo -u sbuser /scratchbox/login apt-get update
sudo -u sbuser /scratchbox/login fakeroot apt-get -f install
apt-get -y install xserver-xephyr
apt-get -y install vncserver
#chown -R sbuser /scratchbox/users/sbuser/scratchbox
}

function maemo {
scratchbox
maemo-sdk
}

function build-feisty {
run-ami $BASE_AMI
authorize-ssh
remote create-ubuntu-image
remote bundle-image ubuntu704base.img
publish ubuntu704base.img | tee ubuntu-ami-image.txt
halt-ami
}

function patch-feisty {
run-ami $FEISTY_AMI
remote patch-ubuntu
remote bundle-vol patched.img
publish patched.img | tee ubuntu-patched-ami-image.txt
halt-ami
}

function install-maemo {
run-ami $FEISTY2_AMI
remote maemo
remote bundle-vol maemo.img
publish maemo.img | tee maemo-ami-image.txt
halt-ami
}

function upgrade-maemo {
wget http://repository.maemo.org/stable/3.2/maemo-sdk-nokia-binaries_3.2.sh
chmod +x ./maemo-sdk-nokia-binaries_3.2.sh
./maemo-sdk-nokia-binaries_3.2.sh -y
# Must accept license

cat <<EOSBUP >/scratchbox/users/sbuser/home/sbuser/sb_up
sb-conf select SDK_X86
fakeroot apt-get -y install maemo-explicit
sb-conf select SDK_ARMEL
fakeroot apt-get -y install maemo-explicit
apt-get update
fakeroot apt-get -f install
fakeroot apt-get -y -f dist-upgrade
# May need to choose to overwrite some files

sb-conf select SDK_X86
apt-get update
fakeroot apt-get -f install
fakeroot apt-get -y -f dist-upgrade
# May need to choose to overwrite some files

echo "deb-src http://repository.maemo.org/ maemo3.2 free" >> /etc/apt/sources.list
fakeroot apt-get update
EOSBUP

chown sbuser /scratchbox/users/sbuser/home/sbuser/sb_up
chmod +x /scratchbox/users/sbuser/home/sbuser/sb_up
sudo -u sbuser /scratchbox/login ./sb_up

}

function create-gentoo-image {
##
## This portion runs on FC4 and creates a base Ubuntu image
##
set -e

# Set up a filesystem image
dd if=/dev/zero of=/mnt/gentoo2007_0.img bs=1M count=4096
mkfs.ext3 -F -j -m 0 /mnt/gentoo2007_0.img

mkdir /gentoo
mount /mnt/gentoo2007_0.img /gentoo -o loop

cd /tmp
wget http://ftp.ucsb.edu/pub/mirrors/linux/gentoo/releases/x86/2007.0/stages/stage3-i686-2007.0.tar.bz2

cd /gentoo
tar xvfjp /tmp/stage3-i686-2007.0.tar.bz2
wget http://s3.amazonaws.com/ec2-downloads/modules-2.6.16-ec2.tgz

# Here we write a script that is to be executed in the context of the new
# filesystem using chroot.
cat <<EOCHROOT >/gentoo/install-script
#!/bin/bash
localedef -i en_US -c -f UTF-8 en_US.UTF-8
echo "US/Central" >/etc/timezone
ln -s /usr/share/zoneinfo/US/Central /etc/localtime

ln -s /dev/sda1 /dev/ROOT
ln -s /dev/sda3 /dev/SWAP

cat <<EOF >/etc/fstab
/dev/ROOT               /               ext3            noatime         0 1
/dev/SWAP               none            swap            sw              0 0
/dev/sda2               /mnt            ext3            defaults        0 0
shm                     /dev/shm        tmpfs           nodev,nosuid,noexec     0 0
EOF

cat <<EOF >>/etc/conf.d/net
#auto lo
#iface lo inet loopback
#auto eth0
#iface eth0 inet dhcp
EOF

# When you use the -k argument to ec2run, the ssh key file is installed on the
# instance as /mnt/openssh_id.pub. This rc.local copies it over to the root
# account so that you can actually use it to login. The code is just copied
# verbatim from one of the pre-made EC2 images.

cat <<EOF >>/etc/conf.d/local.start

# Fetch any credentials present in the ephemeral store:
if [ ! -d /root/.ssh ] ; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
fi

# Fetch ssh key for root
wget http://169.254.169.254/2007-01-19/meta-data/public-keys/0/openssh-key
mv -f openssh-key /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# vim:ts=4
EOF

cd /root
tar -C / -zxf modules-2.6.16-ec2.tgz

# Disable the root password
passwd -d root
passwd -l root

# Need to configure ssh
rc-update add sshd default

EOCHROOT

chroot /gentoo /bin/bash /install-script
rm -f /gentoo/install-script
rm -f /gentoo/modules-2.6.16-ec2.tgz

umount /gentoo
}

function configure-gentoo {
cp /usr/share/zoneinfo/US/Central /etc/localtime
# sshd is already done
#rc-update add sshd default
emerge --sync
emerge portage
# resolve configuration file conflicts?
# download java
echo LINGUAS="en" >> /etc/make.conf
#USE="ruby apache2 postgres gd xml jpeg png gif json colordiff subversion curl php mailman perl webdav" emerge subversion apache postgresql php vim xen-tools xen screen conf-update gentoo-syntax vcscommand dev-java/ant ruby rails curl dhcpcd mediawiki lynx jpgraph portage java aes chkconfig dev-util/git slocate rpm logger mailman sudo sqlite pcel++ mailman commons-logging rhino cvs cvsps gd webalizer
USE="apache2 postgres gd xml jpeg png gif json colordiff curl php mailman perl webdav" emerge screen
USE="apache2 postgres gd xml jpeg png gif json colordiff curl php mailman perl webdav" emerge dev-java/sun-jdk subversion apache postgresql php vim conf-update app-vim/gentoo-syntax dev-java/ant curl dev-php5/jpgraph dev-util/git slocate rpm logger mailman sudo commons-logging rhino cvs cvsps gd webalizer
USE="apache2 postgres gd xml jpeg png gif json colordiff curl php mailman perl webdav" ACCEPT_KEYWORDS="~x86" emerge gitweb xen-tools xen app-vim/vcscommand
#gem install ruby-openid
#gem install postgress
#su - postgres
# add gforge and rails databases/users
#java-config --set-system-classpath
# download helma
wget http://adele.helma.org/download/helma/1.6.1/helma-1.6.1.tar.gz
wget http://s3.amazonaws.com/ec2-downloads/modules-2.6.16-ec2.tgz
tar -C / -zxf /modules-2.6.16-ec2.tgz
rpm -i --nodeps ec2-ami-tools.noarch.rpm
#ln -s ../../site_ruby/aes
/etc/init.d/vixie-cron start
rc-update add vixie-cron default
}

$*

