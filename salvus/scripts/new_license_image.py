#!/usr/bin/env python

import argparse, os, sys, time
VM_PATH = os.path.join(os.environ['HOME'], 'vm/images/license/')

def cmd(s):
    print s
    if os.system(s):
        raise RuntimeError("error executing '%s'"%s)

cmd("ls -lth %s|head -5"%VM_PATH)

parser = argparse.ArgumentParser(description="Create a new VM image.")
parser.add_argument("--prev", dest="prev", type=str, help="previous vm image name", default="")
parser.add_argument("--next", dest="next",  type=str, help="new vm image name", default="")
args = parser.parse_args()

prev = args.prev
next = args.next

if prev == "":
   # make it the most recent image
   prev = os.popen("ls -1t %s/*.qcow2|head -1"%VM_PATH).read().strip().rstrip('.qcow2')

if next == "":
   # make image name sagemathcloud-date
   next = time.strftime("sagemathcloud-%Y-%m-%d-%H%M")


defined_machines = os.popen("virsh_list").read()

for machine in [prev, next]:
    if machine in defined_machines:
        print "%s is currently defined.  Please undefine it before proceeding further, in order to avoid any possible corruption."%machine
        sys.exit(1)

prev_path = os.path.join(VM_PATH, prev + '.qcow2')
next_path = os.path.join(VM_PATH, next + '.qcow2')

if not os.path.exists(prev_path):
    raise ValueError("previous vm image doesn't exist -- " + prev_path)

if os.path.exists(next_path):
    raise ValueError("next vm image already exists -- " + next_path)

cmd("qemu-img create -b %s -f qcow2 %s"%(prev_path, next_path))
cmd("chgrp kvm %s; chmod g+rw %s"%(next_path, next_path))

cmd("virt-install --connect qemu:///system --cpu host --network network:default,model=virtio --name %s --vcpus=4 --ram 16000 --import --disk %s,device=disk,bus=virtio,format=qcow2,cache=writeback --noautoconsole --graphics vnc,port=12505"%(next,next_path))

print "Booting..."

while True:
    ip = os.popen("kvm_addresses.py %s"%next).read().strip()
    if not ip:
        print "waiting for ip address..."
        time.sleep(2)
    else:
        print "The ip address is: '%s'"%ip
        break

print """
You probably want to do something like this:

    sshvm %s
    sudo su
    ./update_salvus
    apt-get update; apt-get upgrade

    reboot -h now
    sshvm
    sudo shutdown -h now

 Then

    virsh undefine %s
    cd vm/images/base/
    ./push

"""%(next, next, next)