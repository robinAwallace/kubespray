data "exoscale_template" "os_image" {
  for_each = var.machines

  zone = var.zone
  name = each.value.boot_disk.image_name != "" ? each.value.boot_disk.image_name : ""
  id   = each.value.boot_disk.image_id != "" ? each.value.boot_disk.image_id : ""
}

data "exoscale_compute_instance" "master_nodes" {
  for_each = exoscale_compute_instance.master

  id   = each.value.id
  zone = var.zone
}

data "exoscale_compute_instance" "worker_nodes" {
  for_each = exoscale_compute_instance.worker

  id   = each.value.id
  zone = var.zone
}

resource "exoscale_private_network" "private_network" {
  zone = var.zone
  name = "${var.prefix}-network"

  start_ip = cidrhost(var.private_network_cidr, 1)
  # cidr -1 = Broadcast address
  # cidr -2 = DHCP server address (exoscale specific)
  end_ip  = cidrhost(var.private_network_cidr, -3)
  netmask = cidrnetmask(var.private_network_cidr)
}

resource "exoscale_compute_instance" "master" {
  for_each = {
    for name, machine in var.machines :
    name => machine
    if machine.node_type == "master"
  }

  name               = "${var.prefix}-${each.key}"
  template_id        = data.exoscale_template.os_image[each.key].id
  type               = "${each.value.family}.${each.value.size}"
  disk_size          = each.value.boot_disk.root_partition_size + each.value.boot_disk.node_local_partition_size + each.value.boot_disk.ceph_partition_size
  state              = "running"
  zone               = var.zone
  security_group_ids = [exoscale_security_group.master_sg.id]

  elastic_ip_ids = [exoscale_elastic_ip.control_plane_lb.id]

  network_interface {
    network_id = exoscale_private_network.private_network.id
  }

  user_data = templatefile(
    "${path.module}/templates/cloud-init.tmpl",
    {
      eip_ip_address            = exoscale_elastic_ip.ingress_controller_lb.ip_address
      node_local_partition_size = each.value.boot_disk.node_local_partition_size
      ceph_partition_size       = each.value.boot_disk.ceph_partition_size
      root_partition_size       = each.value.boot_disk.root_partition_size
      node_type                 = "master"
      ssh_public_keys           = var.ssh_public_keys
    }
  )
}

resource "exoscale_compute_instance" "worker" {
  for_each = {
    for name, machine in var.machines :
    name => machine
    if machine.node_type == "worker"
  }

  name               = "${var.prefix}-${each.key}"
  template_id        = data.exoscale_template.os_image[each.key].id
  type               = "${each.value.family}.${each.value.size}"
  disk_size          = each.value.boot_disk.root_partition_size + each.value.boot_disk.node_local_partition_size + each.value.boot_disk.ceph_partition_size
  state              = "Running"
  zone               = var.zone
  security_group_ids = [exoscale_security_group.worker_sg.id]

  elastic_ip_ids = [exoscale_elastic_ip.ingress_controller_lb.id]

  network_interface {
    network_id = exoscale_private_network.private_network.id
  }

  user_data = templatefile(
    "${path.module}/templates/cloud-init.tmpl",
    {
      eip_ip_address            = exoscale_elastic_ip.ingress_controller_lb.ip_address
      node_local_partition_size = each.value.boot_disk.node_local_partition_size
      ceph_partition_size       = each.value.boot_disk.ceph_partition_size
      root_partition_size       = each.value.boot_disk.root_partition_size
      node_type                 = "worker"
      ssh_public_keys           = var.ssh_public_keys
    }
  )
}

resource "exoscale_security_group" "master_sg" {
  name        = "${var.prefix}-master-sg"
  description = "Security group for Kubernetes masters"
}

resource "exoscale_security_group_rules" "master_sg_rules" {
  security_group_id = exoscale_security_group.master_sg.id

  # SSH
  ingress {
    protocol  = "TCP"
    cidr_list = var.ssh_whitelist
    ports     = ["22"]
  }

  # Kubernetes API
  ingress {
    protocol  = "TCP"
    cidr_list = var.api_server_whitelist
    ports     = ["6443"]
  }
}

resource "exoscale_security_group" "worker_sg" {
  name        = "${var.prefix}-worker-sg"
  description = "security group for kubernetes worker nodes"
}

resource "exoscale_security_group_rules" "worker_sg_rules" {
  security_group_id = exoscale_security_group.worker_sg.id

  # SSH
  ingress {
    protocol  = "TCP"
    cidr_list = var.ssh_whitelist
    ports     = ["22"]
  }

  # HTTP(S)
  ingress {
    protocol  = "TCP"
    cidr_list = ["0.0.0.0/0"]
    ports     = ["80", "443"]
  }

  # Kubernetes Nodeport
  ingress {
    protocol  = "TCP"
    cidr_list = var.nodeport_whitelist
    ports     = ["30000-32767"]
  }
}

resource "exoscale_elastic_ip" "ingress_controller_lb" {
  zone = var.zone
  healthcheck {
    mode         = "http"
    port         = 80
    uri          = "/healthz"
    interval     = 10
    timeout      = 2
    strikes_ok   = 2
    strikes_fail = 3
  }
}

resource "exoscale_elastic_ip" "control_plane_lb" {
  zone = var.zone
  healthcheck {
    mode         = "tcp"
    port         = 6443
    interval     = 10
    timeout      = 2
    strikes_ok   = 2
    strikes_fail = 3
  }
}
