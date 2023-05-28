#!/bin/bash

# update
yum update -y

#install jq
yum install -y jq

#install git
yum install -y git

# enable ssm agent
echo "export AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)" >> /etc/bashrc
echo "export AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)" >> /etc/bashrc
yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# install aws cli
yum install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && ./aws/install

# install kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.25.9/2023-05-11/bin/linux/amd64/kubectl
chmod +x ./kubectl
mv ./kubectl /usr/local/bin/kubectl

# store cluster name in env variable
export CLUSTER_NAME=$(aws eks list-clusters --output text --query 'clusters[0]')

#create kubeconfig command and store it in the file in home directory
export AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
echo "aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION" >> /home/ssm-user/update_kubeconfig_command.txt