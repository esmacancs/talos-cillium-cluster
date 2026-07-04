# -*- mode: ruby -*-
# vi: set ft=ruby :

# ─── Configuration ───────────────────────────────────────────────────────────
CLUSTER_NAME   = ENV.fetch("CLUSTER_NAME", "talos")
CONTROL_COUNT  = ENV.fetch("CONTROL_COUNT", 3).to_i
WORKER_COUNT   = ENV.fetch("WORKER_COUNT", 1).to_i
CP_CPUS        = ENV.fetch("CP_CPUS", 2).to_i
CP_MEMORY      = ENV.fetch("CP_MEMORY", 2048)
WORKER_CPUS    = ENV.fetch("WORKER_CPUS", 1).to_i
WORKER_MEMORY  = ENV.fetch("WORKER_MEMORY", 1024)
DISK_SIZE      = ENV.fetch("DISK_SIZE", "10G")
ISO_PATH       = ENV.fetch("ISO_PATH", "/tmp/metal-amd64.iso")

# ─── ISO Download (runs once on the host) ────────────────────────────────────
if !File.exist?(ISO_PATH)
  puts "==> Downloading Talos ISO to #{ISO_PATH} ..."
  url = "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso"
  system("wget", "--progress=bar:force", "-O", ISO_PATH, url) || begin
    puts "==> wget failed; trying curl ..."
    system("curl", "-fL", "-o", ISO_PATH, url) || fail("Cannot download Talos ISO")
  end
end

# ─── Vagrant Configuration ──────────────────────────────────────────────────
Vagrant.configure("2") do |config|
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "kvm"
    libvirt.connect_via_ssh = false
    libvirt.qemu_use_session = false
  end

  # ── NTP Server (Ubuntu VM with chrony) ─────────────────────────────────
  config.vm.define "ntp-server" do |ntp|
    ntp.vm.box = "bento/ubuntu-24.04"
    ntp.vm.hostname = "ntp-server"
    ntp.vm.provider :libvirt do |domain|
      domain.memory = 512
      domain.cpus   = 1
      domain.management_network_mac = "52:54:00:aa:bb:01"
    end
    ntp.vm.provision "shell", path: "scripts/setup-ntp-server.sh"
  end

  # ── Control Plane Nodes ────────────────────────────────────────────────
  (1..CONTROL_COUNT).each do |i|
    config.vm.define "#{CLUSTER_NAME}-control-plane-#{i}" do |node|
      node.vm.provider :libvirt do |domain|
        domain.cpus      = CP_CPUS
        domain.memory    = CP_MEMORY
        domain.serial :type => "file",
                      :source => {:path => "/tmp/#{CLUSTER_NAME}-control-plane-#{i}.log"}
        domain.storage :file, :device => :cdrom, :path => ISO_PATH
        domain.storage :file, :size => DISK_SIZE, :type => 'raw'
        domain.boot 'hd'
        domain.boot 'cdrom'
      end
    end
  end

  # ── Worker Nodes ───────────────────────────────────────────────────────
  (1..WORKER_COUNT).each do |i|
    config.vm.define "#{CLUSTER_NAME}-worker-#{i}" do |node|
      node.vm.provider :libvirt do |domain|
        domain.cpus      = WORKER_CPUS
        domain.memory    = WORKER_MEMORY
        domain.serial :type => "file",
                      :source => {:path => "/tmp/#{CLUSTER_NAME}-worker-#{i}.log"}
        domain.storage :file, :device => :cdrom, :path => ISO_PATH
        domain.storage :file, :size => DISK_SIZE, :type => 'raw'
        domain.boot 'hd'
        domain.boot 'cdrom'
      end
    end
  end
end
