provider azurerm {
	version = "~> 1.17.0"
  # optional: subscription_id 
}

# Update these variables to suit your needs 
variable "count" {default = 2} # The number of app server instances to spin up
variable "instance_type" {default = "Standard_D1_v2"} # Azure instance type
variable "location" {default = "eastus"} # Which Azure region?
variable "domainprefix" {default = "dg"} # Choose a unique prefix to ensure there are no DNS naming collisions

# Create a resource group to contain everything
resource "azurerm_resource_group" "looker" {
  name     = "lookerrg"
  location = "${var.location}"
}

# Create a virtual network
resource "azurerm_virtual_network" "looker" {
  name                = "lookervn"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
}

# Create a subnet
resource "azurerm_subnet" "looker" {
  name                 = "lookersub"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
  virtual_network_name = "${azurerm_virtual_network.looker.name}"
  address_prefix       = "10.0.2.0/24"
}

# Create a public IP address to assign to the load balancer
resource "azurerm_public_ip" "looker" {
  name                         = "PublicIPForLB"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  public_ip_address_allocation = "static"
  domain_name_label            = "${var.domainprefix}-looker"
  idle_timeout_in_minutes      = 30
  
  tags {
    environment = "looker"
  }
}

# Create public IPs to connect to each instance individually
resource "azurerm_public_ip" "pubip" {
  count                        = "${var.count}"
  name                         = "lookerpip-${count.index}"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  public_ip_address_allocation = "Dynamic"
  domain_name_label            = "${var.domainprefix}-lookerapp${count.index}"
  idle_timeout_in_minutes      = 30

  tags {
    environment = "looker"
  }
}

# Create a load balancer
resource "azurerm_lb" "looker" {
  name                = "lookerlb"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
  sku                 = "basic"

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = "${azurerm_public_ip.looker.id}"
  }
}

# Create a backend pool to contain the VMs associated to the load balancer
resource "azurerm_lb_backend_address_pool" "looker" {
  resource_group_name = "${azurerm_resource_group.looker.name}"
  loadbalancer_id     = "${azurerm_lb.looker.id}"
  name                = "BackEndAddressPool"
}

# Create a network interfaces for each of the VMs to use
resource "azurerm_network_interface" "looker" {
  count = "${var.count}"
  name                = "lookernic-${count.index}"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  ip_configuration {
    name                          = "lookeripconfiguration${count.index}"
    subnet_id                     = "${azurerm_subnet.looker.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${element(azurerm_public_ip.pubip.*.id, count.index)}"
  }
}

# Associate each network interface to the backend pool for the load balancer
resource "azurerm_network_interface_backend_address_pool_association" "looker" {
  count = "${var.count}"
  network_interface_id    = "${element(azurerm_network_interface.looker.*.id, count.index)}"
  ip_configuration_name   = "lookeripconfiguration${count.index}"
  backend_address_pool_id = "${azurerm_lb_backend_address_pool.looker.id}"
}

# Create an instance health probe for the load balancer rule
resource "azurerm_lb_probe" "looker" {
  resource_group_name = "${azurerm_resource_group.looker.name}"
  loadbalancer_id     = "${azurerm_lb.looker.id}"
  name                = "lookerhealthprobe"
  port                = "9999"
  protocol            = "tcp"
}

# Create a load balancer rule to route inbound traffic on the public IP port 443 to port 9999 of an instance
resource "azurerm_lb_rule" "looker" {
  resource_group_name            = "${azurerm_resource_group.looker.name}"
  loadbalancer_id                = "${azurerm_lb.looker.id}"
  name                           = "LBRule"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 9999
  backend_address_pool_id        = "${azurerm_lb_backend_address_pool.looker.id}"
  probe_id                       = "${azurerm_lb_probe.looker.id}"
  frontend_ip_configuration_name = "PublicIPAddress"
# This is going to be a problem - the maximum timeout is not long enough!
  idle_timeout_in_minutes        = 30
}

# Create a load balancer rule to route inbound traffic on the public IP port 19999 to port 19999 of an instance (for API)
resource "azurerm_lb_rule" "looker" {
  resource_group_name            = "${azurerm_resource_group.looker.name}"
  loadbalancer_id                = "${azurerm_lb.looker.id}"
  name                           = "LBRuleforAPI"
  protocol                       = "Tcp"
  frontend_port                  = 19999
  backend_port                   = 19999
  backend_address_pool_id        = "${azurerm_lb_backend_address_pool.looker.id}"
  probe_id                       = "${azurerm_lb_probe.looker.id}"
  frontend_ip_configuration_name = "PublicIPAddress"
  idle_timeout_in_minutes        = 30
}

# Create an Azure storage account
resource "azurerm_storage_account" "looker" {
  name                     = "${var.domainprefix}lookerstorage"
  resource_group_name      = "${azurerm_resource_group.looker.name}"
  location                 = "${azurerm_resource_group.looker.location}"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags {
    environment = "looker"
  }
}

# Retrieve the keys to the storage account so we can use them later in the provisioning script for the app instances
data "azurerm_storage_account" "looker" {
  depends_on           = ["azurerm_storage_account.looker"]
  name                 = "${var.domainprefix}lookerstorage"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
}

# Create a container within the storage account
resource "azurerm_storage_container" "looker" {
  name                  = "vhds"
  resource_group_name   = "${azurerm_resource_group.looker.name}"
  storage_account_name  = "${azurerm_storage_account.looker.name}"
  container_access_type = "private"
}

# Create a bucket / file share within the container
resource "azurerm_storage_share" "looker" {
  name = "lookerfiles"

  resource_group_name  = "${azurerm_resource_group.looker.name}"
  storage_account_name = "${azurerm_storage_account.looker.name}"

  quota = 50
}

# Create a network security group to restrict port traffic
resource "azurerm_network_security_group" "looker" {
  name                = "lookersg"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  security_rule {
    name                       = "Port_9999"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9999"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Port_443"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Port_19999"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "19999"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags {
    environment = "looker"
  }
}

# Create an availability set - not sure if this is actually useful
resource "azurerm_availability_set" "looker" {
  name                = "lookeravailabilityset"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  tags {
    environment = "Production"
  }
}

# Create the virtual machines themselves!
resource "azurerm_virtual_machine" "looker" {

  # TODO: replace the azurerm_virtual_machine dependency with azurerm_mysql_database
  depends_on                       = ["azurerm_availability_set.looker","azurerm_virtual_machine.lookerdb"]

  name                             = "lookerapp-${count.index}"
  location                         = "${azurerm_resource_group.looker.location}"
  resource_group_name              = "${azurerm_resource_group.looker.name}"
  network_interface_ids            = ["${element(azurerm_network_interface.looker.*.id, count.index)}"]
  vm_size                          = "${var.instance_type}"
  count                            = "${var.count}"
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true
  availability_set_id              = "${azurerm_availability_set.looker.id}"

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name          = "lookerapp-${count.index}-osdisk"
    vhd_uri       = "${azurerm_storage_account.looker.primary_blob_endpoint}${azurerm_storage_container.looker.name}/lookerapp-${count.index}-osdisk.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  os_profile {
    computer_name  = "lookerapp${count.index}"
    admin_username = "root_looker"
    admin_password = "looker"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "${file("~/.ssh/id_rsa.pub")}"
      path = "/home/root_looker/.ssh/authorized_keys"
    }
  }

  connection {
    host = "${var.domainprefix}-lookerapp${count.index}.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
    user = "root_looker"
    type = "ssh"
    private_key = "${file("~/.ssh/id_rsa")}"
    timeout = "1m"
    agent = true
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install libssl-dev -y",
      "sudo apt-get install cifs-utils -y",
      "sudo apt-get install fonts-freefont-otf -y",
      "sudo apt-get install chromium-browser -y",
      "curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/systemd/looker.service -O",
      "sudo mv looker.service /etc/systemd/system/looker.service",
      "sudo chmod 664 /etc/systemd/system/looker.service",
      "sudo sed -i 's/TimeoutStartSec=500/TimeoutStartSec=500\nEnvironment=CHROMIUM_PATH=\\/usr\\/bin\\/chromium-browser/' /etc/systemd/system/looker.service",
      "echo \"Environment=CHROMIUM_PATH=/usr/bin/chromium-browser\" | sudo tee -a /etc/systemd/system/looker.service",
      "echo \"net.ipv4.tcp_keepalive_time=200\" | sudo tee -a /etc/sysctl.conf",
      "echo \"net.ipv4.tcp_keepalive_intvl=200\" | sudo tee -a /etc/sysctl.conf",
      "echo \"net.ipv4.tcp_keepalive_probes=5\" | sudo tee -a /etc/sysctl.conf",
      "echo \"looker     soft     nofile     4096\" | sudo tee -a /etc/security/limits.conf",
      "echo \"looker     hard     nofile     4096\" | sudo tee -a /etc/security/limits.conf",
      "sudo groupadd looker",
      "sudo useradd -m -g looker looker",
      "sudo mkdir /home/looker/looker",
      "sudo chown looker:looker /home/looker/looker",
      "cd /home/looker",
      "sudo curl -L -b \"oraclelicense=a\" http://download.oracle.com/otn-pub/java/jdk/8u191-b12/2787e4a523244c269598db4e85c51e0c/jdk-8u191-linux-x64.tar.gz -O",
      "sudo tar zxvf jdk-8u191-linux-x64.tar.gz",
      "sudo chown looker:looker -R jdk1.8.0_191",
      "sudo rm jdk-8u191-linux-x64.tar.gz",
      "cd /home/looker/looker",
      "sudo curl https://s3.amazonaws.com/download.looker.com/aeHee2HiNeekoh3uIu6hec3W/looker-6.0-latest.jar -O",
      "sudo mv looker-6.0-latest.jar looker.jar",
      "sudo chown looker:looker looker.jar",
      "sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O",
      "sudo chmod 0750 looker",
      "sudo chown looker:looker looker",
      "export IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')",
      "export CMD=\"sudo sed -i 's/LOOKERARGS=\\\"\\\"/LOOKERARGS=\\\"--no-daemonize -d \\/home\\/looker\\/looker\\/looker-db.yml --clustered -H $IP --shared-storage-dir \\/mnt\\/lookerfiles\\\"/' /home/looker/looker/looker\"",
      "echo $CMD | bash",
      # TODO: the database host will need to be changed when using an azurerm_mysql_database resource
      "echo \"host: ${var.domainprefix}-lookerdb.${azurerm_resource_group.looker.location}.cloudapp.azure.com\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"username: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      # TODO: move password into a secret .tfvars file that isn't tracked in the repository
      "echo \"password: password\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"database: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"dialect: mysql\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"port: 3306\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "sudo update-alternatives --install /usr/bin/java java /home/looker/jdk1.8.0_191/bin/java 100",
      "sudo update-alternatives --install /usr/bin/javac javac /home/looker/jdk1.8.0_191/bin/javac 100",
      "sudo mkdir -p /mnt/lookerfiles",
      "sudo mount -t cifs //${azurerm_storage_account.looker.name}.file.core.windows.net/${azurerm_storage_share.looker.name} /mnt/lookerfiles -o vers=3.0,username=${azurerm_storage_account.looker.name},password=${data.azurerm_storage_account.looker.primary_access_key},dir_mode=0777,file_mode=0777,serverino",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable looker.service",
      "sudo systemctl start looker",
    ]
  }

  tags {
    environment = "looker"
  }
}

output " ***** Important Message! ***** " {
  value = "Note that because the database initialization step takes a little while, the first Looker instance to initialize will start successfully, but the remaining instances will fail to start, because multiple database initializations cannot be run at the same time. When you have confirmed that the first instance has completed the database initialization, you must SSH into each remaining instance and run 'sudo systemctl start looker' manually."
}

output "Instances" {
  value = "Started ${var.domainprefix}-lookerapp0.${azurerm_resource_group.looker.location}.cloudapp.azure.com through ${var.domainprefix}-lookerapp${var.count - 1}.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
}

output "Load Balanced Primary URL" {
  value = "Started ${var.domainprefix}-looker.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
}

####################################################################################
## BEGIN WORKAROUND FOR "MICROSOFT AZURE DATABASE FOR MYSQL" AUTHENTICATION ISSUE ##
##                                                                                 #
## The following should be replaced with an azurerm_mysql_database resource as     #
## soon as possible. We do not want to manage a VM for the database server and     #
## this setup is literally as insecure as it could be. This is necessary due to    #
## the "Handshake failed" error  helltool returns when connecting to a managed     #
## Azure MySQL database, maybe because of the use of a fully-qualified username.   #
##                                                                                 #
####################################################################################

# Create a public IP address for the DB instance (at least delete this afterwards)
resource "azurerm_public_ip" "lookerdb" {
  name                         = "PublicIPForDB"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  public_ip_address_allocation = "static"
  domain_name_label            = "${var.domainprefix}-lookerdb"
  idle_timeout_in_minutes      = 30
  
  tags {
    environment = "looker"
  }
}

# Create a network interface for the DB instance
resource "azurerm_network_interface" "lookerdb" {
  name                = "lookerdbnic"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  ip_configuration {
    name                          = "lookeripconfigurationdb"
    subnet_id                     = "${azurerm_subnet.looker.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.lookerdb.id}"
  }
}

resource "azurerm_virtual_machine" "lookerdb" {
  depends_on                       = ["azurerm_availability_set.looker"]
  name                             = "lookerdb"
  location                         = "${azurerm_resource_group.looker.location}"
  resource_group_name              = "${azurerm_resource_group.looker.name}"
  network_interface_ids            = ["${azurerm_network_interface.lookerdb.id}"]
  vm_size                          = "${var.instance_type}"
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true
  availability_set_id              = "${azurerm_availability_set.looker.id}"

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name          = "lookerdb-osdisk"
    vhd_uri       = "${azurerm_storage_account.looker.primary_blob_endpoint}${azurerm_storage_container.looker.name}/lookerdb-osdisk.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  os_profile {
    computer_name  = "lookerdb"
    admin_username = "root_looker"
    admin_password = "looker"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "${file("~/.ssh/id_rsa.pub")}"
      path = "/home/root_looker/.ssh/authorized_keys"
    }
  }

  connection {
    host = "${var.domainprefix}-lookerdb.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
    user = "root_looker"
    type = "ssh"
    private_key = "${file("~/.ssh/id_rsa")}"
    timeout = "1m"
    agent = true
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install mysql-server-5.7 -y",
      "sudo sed -i 's/bind-address/#bind-address/' /etc/mysql/mysql.conf.d/mysqld.cnf",
      "sudo /etc/init.d/mysql restart",
      "sudo mysql -u root -e \"CREATE USER looker; SET PASSWORD FOR looker = PASSWORD('password'); CREATE DATABASE looker DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci; GRANT ALL ON looker.* TO looker@'%'; GRANT ALL ON looker_tmp.* TO 'looker'@'%'; FLUSH PRIVILEGES;\"",
    ]
  }

  tags {
    environment = "looker"
  }
}

##################################################################################
## END WORKAROUND FOR "MICROSOFT AZURE DATABASE FOR MYSQL" AUTHENTICATION ISSUE ##
##################################################################################