# Infrastructure for Yandex Managed Service for Valkey cluster and Bitrix VM
#
# RU: https://cloud.yandex.ru/docs/managed-valkey/tutorials/yc-valkey-as-1c-cache-storage
# EN: https://cloud.yandex.com/en/docs/managed-valkey/tutorials/yc-valkey-as-1c-cache-storage

# Specify the following settings

locals {
  # The following settings are to be specified by the user. Change them as you wish.
  valkey_password = "" # Password of the user in Managed Service for Valkey cluster

  # The following settings are predefined. Change them only if necessary.

  # List of IP ranges for availability zones
  zones = {
    "ru-central1-a" = "10.128.0.0/24"
    "ru-central1-d" = "10.128.1.0/24"
  }

  bitrix_image_id         = "fd8r9m9htd3crjj9v7fk"  # ID of the Bitrix image in Marketplace
  vm_user_name            = "bitrix"                # Name of the user in Virtual machine
  bitrix_document_root    = "/home/bitrix/www"      # Root path for Bitrix VM
  vm_zone                 = "ru-central1-a"         # Availability zone for Bitrix VM
  ssh_allowed_cidr_blocks = ["0.0.0.0/0"]           # List of allowed CIDR blocks for SSH connection
  ssh_public_key_path     = "~/.ssh/id_ed25519.pub" # Path to the public ssh key file
}

resource "yandex_vpc_network" "net" {
  description = "Network for the Managed Service for Valkey cluster and Bitrix Virtual Machine"
  name        = "bitrix-cache-net"
}

resource "yandex_vpc_subnet" "subnet" {
  for_each       = local.zones
  description    = "Subnet in the ${each.key} availability zone"
  name           = "bitrix-cache-subnet-${each.key}"
  network_id     = yandex_vpc_network.net.id
  zone           = each.key
  v4_cidr_blocks = [each.value]
}

resource "yandex_vpc_security_group" "bitrix" {
  description = "Security group for the Bitrix Virtual Machine"
  name        = "bitrix-vm-sg"
  network_id  = yandex_vpc_network.net.id

  ingress {
    protocol       = "TCP"
    description    = "Allow SSH access to the Bitrix VM"
    v4_cidr_blocks = local.ssh_allowed_cidr_blocks
    port           = 22
  }

  ingress {
    protocol       = "TCP"
    description    = "Allow HTTP access to the Bitrix site"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  ingress {
    protocol       = "TCP"
    description    = "Allow HTTPS access to the Bitrix site"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  egress {
    protocol       = "ANY"
    description    = "Allow outbound traffic"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

resource "yandex_vpc_security_group" "valkey" {
  description = "Security group for the Managed Service for Valkey cluster"
  name        = "bitrix-cache-sg"
  network_id  = yandex_vpc_network.net.id

  ingress {
    protocol          = "ANY"
    description       = "Allow traffic between Valkey hosts"
    predefined_target = "self_security_group"
  }

  ingress {
    protocol          = "TCP"
    description       = "Allow the Bitrix VM to connect to Valkey"
    security_group_id = yandex_vpc_security_group.bitrix.id
    port              = 6379
  }

  egress {
    protocol       = "ANY"
    description    = "Allow outbound traffic"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_mdb_redis_cluster_v2" "valkey" {
  description        = "Managed Service for Valkey cluster to be used as Bitrix cache"
  name               = "bitrix-cache"
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.net.id
  persistence_mode   = "ON_REPLICAS"
  security_group_ids = [yandex_vpc_security_group.valkey.id]
  announce_hostnames = true
  tls_enabled        = false

  config = {
    version          = "9.1-valkey"
    maxmemory_policy = "ALLKEYS_LRU"
    password         = local.valkey_password
  }

  access = {
    web_sql = true
  }

  modules = {
    valkey_search = { enabled = false }
    valkey_json   = { enabled = false }
    valkey_bloom  = { enabled = false }
  }

  resources = {
    resource_preset_id = "hm3-c2-m8" # 2vCPU, 8 GB RAM
    disk_type_id       = "network-ssd"
    disk_size          = 16 # GB
  }

  hosts = {
    "host-1" = {
      zone      = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.subnet["ru-central1-a"].id
    }
    "host-2" = {
      zone      = "ru-central1-d"
      subnet_id = yandex_vpc_subnet.subnet["ru-central1-d"].id
    }
  }
}

resource "yandex_compute_instance" "bitrix" {
  description               = "Virtual Machine with Bitrix image installed to run a website on"
  name                      = "bitrix-cache-vm"
  platform_id               = "standard-v3"
  zone                      = local.vm_zone
  allow_stopping_for_update = true

  resources {
    cores         = 2
    memory        = 4 # GB
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = local.bitrix_image_id
      type     = "network-ssd"
      size     = 24 # GB
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.subnet[local.vm_zone].id
    security_group_ids = [yandex_vpc_security_group.bitrix.id]
    nat                = true
  }

  metadata = {
    user-data = <<-EOT
      #cloud-config
      users:
        - default
        - name: ${local.vm_user_name}
          groups:
            - sudo
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          lock_passwd: true
          ssh_authorized_keys:
            - ${jsonencode(trimspace(file(pathexpand(local.ssh_public_key_path))))}

      write_files:
        - path: /tmp/bitrix-cache-settings.php
          owner: root:root
          permissions: "0600"
          content: |
            <?php
            return [
                'cache' => [
                    'value' => [
                        'type' => [
                            'class_name' => '\\Bitrix\\Main\\Data\\CacheEngineRedis',
                            'extension' => 'redis',
                        ],
                        'redis' => [
                            'servers' => [
                                [
                                    'host' => 'c-${yandex_mdb_redis_cluster_v2.valkey.cluster_id}.rw.mdb.yandexcloud.net',
                                    'port' => 6379,
                                ],
                            ],
                            'auth' => base64_decode('${base64encode(local.valkey_password)}'),
                            'persistent' => true,
                        ],
                        'sid' => $_SERVER['DOCUMENT_ROOT'] . '#01',
                    ],
                    'readonly' => true,
                ],
            ];

      runcmd:
        - >-
          install -d -o ${local.vm_user_name} -g ${local.vm_user_name} -m 0755
          ${local.bitrix_document_root}/bitrix &&
          install -o ${local.vm_user_name} -g ${local.vm_user_name} -m 0600
          /tmp/bitrix-cache-settings.php
          ${local.bitrix_document_root}/bitrix/.settings_extra.php
      EOT
  }
}

output "valkey_endpoint" {
  description = "Stable read/write endpoint to use when configuring Bitrix cache connections."
  value = {
    host = "c-${yandex_mdb_redis_cluster_v2.valkey.cluster_id}.rw.mdb.yandexcloud.net"
    port = 6379
  }
}

output "bitrix_vm_public_ip" {
  description = "Public IP address of the Bitrix VM."
  value       = yandex_compute_instance.bitrix.network_interface[0].nat_ip_address
}
