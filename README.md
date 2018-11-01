# Use terraform to automatically set up a Looker cluster on Azure

## Prerequisites
1. Download an appropriate [terraform binary](https://www.terraform.io/downloads.html) and ensure `terraform` is in your $PATH
> Optional: read the documentation for the [azurerm provider](https://www.terraform.io/docs/providers/azurerm/index.html) but don't sweat it because there is nothing to configure
2. Install the Azure CLI:
`curl -L https://aka.ms/InstallAzureCli | bash`
3. Login to Azure from the command line by typing `az login`

## Get Started
1. Open a shell and clone this repository
2. Update the prefix variable at the top of the [azure.tf](https://github.com/drewgillson/azure_looker_cluster/blob/master/azure.tf) file.
> The purpose of the prefix is to prevent DNS namespace collisions, there are several resources that get created with public URLs and if multiple people use this script without different prefixes, it could cause issues.
4. Type `terraform init` to set things up
5. Type `terraform apply` and wait about 10 minutes
6. Now you can browse to the Looker welcome screen at [https://*dg*-looker.*eastus*.cloudapp.azure.com](https://dg-looker.eastus.cloudapp.azure.com), where *dg* is the prefix variable you set and *eastus* is the location.
> This URL is the endpoint for the load balancer

## Gotchas and Warnings

Note that because the database initialization step takes a little while, the first Looker instance to initialize will start successfully, but the remaining instances will fail to start, because multiple database initializations cannot be run at the same time. When you have confirmed that the first instance has completed the database initialization, you must SSH into each remaining instance and run `sudo systemctl start looker` manually.

### Do not deploy to production without locking the shared database down! ###