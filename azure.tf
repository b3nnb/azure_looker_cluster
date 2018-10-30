provider azurerm {}

resource "azurerm_resource_group" "looker" {
  name     = "lookerrg"
  location = "East US"
}

resource "azurerm_virtual_network" "looker" {
  name                = "lookervn"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
}

resource "azurerm_subnet" "looker" {
  name                 = "lookersub"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
  virtual_network_name = "${azurerm_virtual_network.looker.name}"
  address_prefix       = "10.0.2.0/24"
}

resource "azurerm_public_ip" "pubip" {
  name                         = "lookerpip"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  public_ip_address_allocation = "Dynamic"
  idle_timeout_in_minutes      = 30

  tags {
    environment = "looker"
  }
}

resource "azurerm_network_interface" "looker" {
  name                = "lookernic"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  ip_configuration {
    name                          = "lookerconfiguration1"
    subnet_id                     = "${azurerm_subnet.looker.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.pubip.id}"
  }
}

resource "azurerm_storage_account" "looker" {
  name                     = "lookerstorage"
  resource_group_name      = "${azurerm_resource_group.looker.name}"
  location                 = "${azurerm_resource_group.looker.location}"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags {
    environment = "looker"
  }
}

resource "azurerm_storage_container" "looker" {
  name                  = "vhds"
  resource_group_name   = "${azurerm_resource_group.looker.name}"
  storage_account_name  = "${azurerm_storage_account.looker.name}"
  container_access_type = "private"
}

resource "azurerm_virtual_machine" "looker" {
  name                  = "lookerapp1"
  location              = "${azurerm_resource_group.looker.location}"
  resource_group_name   = "${azurerm_resource_group.looker.name}"
  network_interface_ids = ["${azurerm_network_interface.looker.id}"]
  vm_size               = "Standard_D2s_V3"
  delete_os_disk_on_termination = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name          = "myosdisk1"
    vhd_uri       = "${azurerm_storage_account.looker.primary_blob_endpoint}${azurerm_storage_container.looker.name}/myosdisk1.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  os_profile {
    computer_name  = "lookerapp1"
    admin_username = "looker"
    admin_password = "looker"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "${file("~/.ssh/id_rsa.pub")}"
      path = "/home/looker/.ssh/authorized_keys"
    }
  }

  tags {
    environment = "looker"
  }
}

resource "azurerm_virtual_machine_extension" "looker" {
  name                 = "lookerapp1"
  location             = "${azurerm_resource_group.looker.location}"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
  virtual_machine_name = "${azurerm_virtual_machine.looker.name}"
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = <<SETTINGS
    {
        "commandToExecute": "sh provision.sh",
        "fileUris": ["https://raw.githubusercontent.com/drewgillson/azure_looker_cluster/master/provision.sh"]
    }
SETTINGS

  tags {
    environment = "looker"
  }
}

output "public_ip_address" {
  description = "The actual ip address allocated for the resource."
  value       = "${azurerm_public_ip.pubip.*.ip_address}"
}