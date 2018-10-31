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
> The purpose of the prefix is to prevent namespace collisions, there are several resources that get created with public URLs and if multiple people use this script without different prefixes, it could cause issues.
4. Type `terraform init` and make sure there are no errors
5. Type `terraform apply` and wait 5-10 minutes
6. Browse to the Looker welcome screen at [https://*dg*-lookerapp*0*.eastus.cloudapp.azure.com:9999/setup](https://dg-lookerapp0.eastus.cloudapp.azure.com:9999/setup), where *dg* is the prefix variable you set, and *0* is an integer corresponding to a provisioned instance.

## TODO

1. Use terraform to configure a shared database, whether an "Azure Database for MySQL Server" managed instance or another compute instance dedicated for the shared database. Note that a shared file system mount is already present at `/mnt/lookerfiles`

> Troubleshooting related to database connection: 
```
# Success with mysql client from app server
mysql -u looker@lookermysql.mysql.database.azure.com -p -h lookermysql.mysql.database.azure.com
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 64849
Server version: 5.6.39.0 MySQL Community Server (GPL)

# First attempt from looker - doesn't like that SSL is required
looker@lookerapp0:~/looker$ ./looker migrate_internal_data looker-db.yml
Source database connection successful
Java::JavaSql::SQLException: Could not connect: SSL connection is required. Please specify SSL options and retry.
Unable to connect to Destination database

# Second attempt from looker with SSL turned off - bad handshake error
looker@lookerapp0:~/looker$ ./looker migrate_internal_data looker-db.yml
Source database connection successful
Java::JavaSql::SQLException: Could not connect: Bad handshake
Unable to connect to Destination database
```

2. Use terraform to create the load balancer

3. Split out other parameters into variables, like the region

4. Use terraform to set up monitoring and alerting for the cluster