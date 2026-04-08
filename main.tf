# Declare what providers (cloud platforms/services) Terraform needs to
# download and use
terraform {
    required_providers {
        aws = {
            # Where to download AWS provider plugin from
            # = official HashiCorp registry
            source = "hashicorp/aws"
            # means any 6.x version
            version = "~> 6.0"
        }
        docker = {
            source = "kreuzwerker/docker"
            version = "3.6.2"
        }
    }
}

# Configure HOW Terraform connects to AWS
# "login settings" for AWS
provider "aws" {
    # us-east-1 = common default, usually cheapest
    # FOR Australia, would use ap-southeast-2 (Sydney)
    region = "us-east-1"
    # Path to file containing AWS access keys
    # This file has AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
    # In production, would use IAM roles or environment variables instead
    shared_credentials_files = ["./credentials"]
}

# variables that only exist within this Terraform config
# Avoid harcoding values in multiple places
locals {
    # Container image to deploy (stored in Github Container Registry)
    # "latest" = always pull the newest version
    image = "ghcr.io/csse6400/taskoverflow:latest"
    database_username = "administrator"
    database_password = "DatabasePassword123"
}

# Create a managed PostgreSQL database on AWS RDS
# RDS = Relational Database Service (AWS manages backups, updates, etc.)
resource "aws_db_instance" "taskoverflow_database" {
    allocated_storage = 20          # Start with 20GB
    max_allocated_storage = 1000    # Auto-scale up to 1TB if needed
    # Database engine configuration
    engine = "postgres"             # Use PostgreSQL
    engine_version = "18"           # PostgreSQL version 18

    # Instance size - determines CPU/RAM
    # db.t3.micro = smallest/cheapest, good for dev/testing
    # Production would use db.r5.large or bigger
    instance_class = "db.t3.micro"

    # Initial db name created on startup
    db_name = "todo"

    # Credentials - referencing the local variables defined above
    username = local.database_username
    password = local.database_password

    # Preset configurations for PostgreSQL
    parameter_group_name = "default.postgres18"

    # true = just delete it (good for dev, dangerous for prod)
    # false = take a backup snapshot before deletion
    skip_final_snapshot = true

    # Which security group controls network access to this DB
    vpc_security_group_ids = [aws_security_group.taskoverflow_database.id]

    # Allow connections from the internet (not just inside AWS VPC)
    # true = accessible from your laptop, EC2, anywhere
    # false = only accessible from within the same AWS network
    # WARNING: true + open security group = security risk in production!
    publicly_accessible = true

    # metadata labels for organisation/billing
    tags = {
        Name = "taskoverflow_database"
    }
}

# Security groups (Firewall rules)
resource "aws_security_group" "taskoverflow_database" {
    # Unique name for this security group in AWS
    name = "taskoverflow_database"
    description = "Allow inbound Postgresql traffic"

    # INBOUND traffice (connection coming IN to the database)
    ingress {
        from_port = 5432                # PostgreSQL's default port
        to_port = 5432                  # Same port (not a range)
        protocol = "tcp"                
        # CIDR block defining WHO can connect
        # 0.0.0.0/0 = EVERYONE on the internet can connect
        # In production, would restrict this to specific IPs
        # e.g, ["10.0.0.,0/16"] for only your VPC
        cidr_blocks = ["0.0.0.0/0"]
    }

    # OUTBOUND traffic (connections going OUT from the database)
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"                 # a-1 = all protocols (TCP, UDP, ICMP, etc.)

        # Allow outbound to anywhere (IPv4 and IPv6)
        cidr_blocks = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }

    tags = {
        Name = "taskoverflow_database"
    }
}

# Fetch the IAM role: LabRole - a super user in the Learner Lab
# which can do everything I can do through the AWS Console
data "aws_iam_role" "lab" {
    name = "LabRole"
}

# Fecth default VPC
data "aws_vpc" "default" {
    default = true
}

# Filter private subnets within the default VPC (required for ECS network config)
data "aws_subnets" "private" {
    filter {
        name = "vpc-id"
        values = [data.aws_vpc.default.id]
    }
}

# Create the ECS cluster - a logical grouping of any images
resource "aws_ecs_cluster" "taskoverflow" {
    name = "taskoverflow"
}


# Create a task definition - a description of the container
# Where we define image, environment variables, port mappings, etc..
# Similar to a server entry in Docker Compose
# DEFINITION line cannot have a trailing space
resource "aws_ecs_task_definition" "taskoverflow" { 
    # name that persists through multiple revisions of the task
    family = "taskoverflow"
    network_mode = "awsvpc" 
    # type of container (fargate, EC2, external)
    requires_compatibilities = ["FARGATE"] 
    cpu = 1024      # equivalent to vCPU
    memory = 2048   # 2GB
    execution_role_arn = data.aws_iam_role.lab.arn 
    
    # Similar to Docker Compose, additional feature: logConfiguration
    # Allow writing logs to AWS CloudWatch
    container_definitions = <<DEFINITION
        [ 
            { 
                    "image": "${local.image}", 
                    "cpu": 1024, 
                    "memory": 2048, 
                    "name": "todo", 
                    "networkMode": "awsvpc", 
                    "portMappings": [ 
                        { 
                            "containerPort": 6400, 
                            "hostPort": 6400 
                        } 
                    ], 
                    "environment": [ 
                        { 
                            "name": "SQLALCHEMY_DATABASE_URI", 
                            "value": "postgresql://${local.database_username}:${local.database_password}@${aws_db_instance.taskoverflow_database.address}:${aws_db_instance.taskoverflow_database.port}/${aws_db_instance.taskoverflow_database.db_name}" 
                        } 
                    ], 
                    "logConfiguration": { 
                        "logDriver": "awslogs", 
                        "options": { 
                            "awslogs-group": "/taskoverflow/todo", 
                            "awslogs-region": "us-east-1", 
                            "awslogs-stream-prefix": "ecs", 
                            "awslogs-create-group": "true" 
                        } 
                    } 
            }
        ] 
        DEFINITION 
}

# A service on which to run the container
# Similar to an auto-scaling group
# Speicfy how many instances of the container we want
resource "aws_ecs_service" "taskoverflow" {
    name = "taskoverflow"
    cluster = aws_ecs_cluster.taskoverflow.id
    task_definition = aws_ecs_task_definition.taskoverflow.arn
    desired_count = 1
    launch_type = "FARGATE"

    network_configuration {
        subnets = data.aws_subnets.private.ids
        security_groups = [aws_security_group.taskoverflow.id]
        assign_public_ip = true
    }
}

resource "aws_security_group" "taskoverflow" { 
    name = "taskoverflow" 
    description = "TaskOverflow Security Group" 
    
    ingress { 
        from_port = 6400 
        to_port = 6400 
        protocol = "tcp" 
        cidr_blocks = ["0.0.0.0/0"] 
    } 
    
    ingress { 
        from_port = 22 
        to_port = 22 
        protocol = "tcp" 
        cidr_blocks = ["0.0.0.0/0"] 
    } 
    
    egress { 
        from_port = 0 
        to_port = 0 
        protocol = "-1" 
        cidr_blocks = ["0.0.0.0/0"] 
    } 
}

# ADDED DOCKER PROVIDER
# With AWS provider, want to authenticate to later push to 
# registry using Docker provider

# ECR credentials for Docker
data "aws_ecr_authorization_token" "ecr_token" {}

provider "docker" {
    registry_auth {
        address = data.aws_ecr_authorization_token.ecr_token.proxy_endpoint
        username = data.aws_ecr_authorization_token.ecr_token.user_name
        password = data.aws_ecr_authorization_token.ecr_token.password
    }
}

# Need to use Terraform to create an ECR repo to push to
resource "aws_ecr_repository" "taskoverflow" {
    name = "taskoverflow"
}

