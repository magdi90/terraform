# terraform
How to build the solution from scratch: 
1- Define terraform google provider
2- create terraform locals variables
3- create google projects using terraform
4- create terraform google compute network 
5- create terraform google compute subnetwork
6- create terraform google compute router
7- create terraform google compute router nat
8- create terraform google compute shared vpc host and service project
9- create terraform google compute subnetwork
10- create terraform google service account
11- create terraform google container cluster
12- create terraform google auto scaler 
13- create terraform google container node pool
14- deploy nginx and create public loadbalancer
15- create terraform google comute firewall
How to test/validate: 
- terraform init # to install the plugins of the provider 
- terraform plan # to check the main.tf file and if there is any error it will shown
- terraform validate # to check the configration file 
- terraform apply # to apply the file 
How to access the public endpoint to visit the website:
- we get the containers ip from the terminal by command line kubectl get svc
Instruction on how to scale up to 10 pods, and then back down to 2 pods:
- by creating a terraform resoures of auto scaling 
