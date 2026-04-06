# DevskinCloud CLI

The official command-line interface for [DevskinCloud](https://cloud.devskin.com). Manage your entire cloud infrastructure -- compute, databases, networking, containers, Kubernetes, CI/CD, and 40+ services -- from a single `devskin` command.

## Installation

### Quick Install (Linux / macOS)

```bash
curl -fsSL https://cloud-api.devskin.com/cli/install.sh | bash
```

This downloads the CLI to `/usr/local/bin/devskin`. Override with `DEVSKIN_INSTALL_DIR`:

```bash
DEVSKIN_INSTALL_DIR="$HOME/.local/bin" curl -fsSL https://cloud-api.devskin.com/cli/install.sh | bash
```

### Homebrew (macOS / Linux)

```bash
brew tap devskin/tap
brew install devskin-cli
```

### Windows (winget)

```powershell
winget install DevskinCloud.CLI
```

### Manual Install

Download `devskin-cli.sh`, place it somewhere in your `$PATH`, and make it executable:

```bash
chmod +x devskin-cli.sh
sudo mv devskin-cli.sh /usr/local/bin/devskin
```

### Requirements

- **bash** 4.0+ (ships with most Linux distros and macOS)
- **curl** or **wget**
- **jq** (recommended) -- falls back to Python for JSON parsing if missing

## Quick Start

```bash
# 1. Configure the CLI with your API endpoint
devskin configure

# 2. Or log in with email/password
devskin login

# 3. Verify authentication
devskin whoami

# 4. Create your first compute instance
devskin compute create --name web-server --type t3.micro --image ami-ubuntu-22

# 5. SSH into it
devskin compute ssh i-12345

# 6. List all instances
devskin compute list
```

## Global Options

| Flag | Description |
|------|-------------|
| `--json` | Output raw JSON instead of formatted tables |
| `--help`, `-h` | Show help for any command |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `DEVSKIN_API_URL` | Override the API base URL (default: `https://api.devskin.cloud`) |
| `DEVSKIN_OUTPUT` | Default output format: `table` or `json` |

## Command Reference

### Authentication

| Command | Description |
|---------|-------------|
| `devskin configure` | Set API URL and authentication token |
| `devskin login` | Authenticate with email and password |
| `devskin logout` | Remove saved token |
| `devskin whoami` | Show current authenticated user |
| `devskin version` | Show CLI version |

### Compute

```
devskin compute list                          List instances
devskin compute create                        Create instance (--name, --type, --image)
devskin compute get ID                        Show instance details
devskin compute start ID                      Start instance
devskin compute stop ID                       Stop instance
devskin compute reboot ID                     Reboot instance
devskin compute terminate ID                  Terminate instance
devskin compute ssh ID                        SSH into instance
```

Aliases: `ec2`

### Database (RDS)

```
devskin db list                               List databases
devskin db create                             Create database (--name, --engine, --class, --storage)
devskin db get ID                             Show database details
devskin db start|stop|reboot ID               Manage database state
devskin db delete ID                          Delete database
devskin db snapshot ID                        Create snapshot (--name)
```

Aliases: `database`, `rds`

### Storage (S3)

```
devskin storage list                          List buckets
devskin storage create                        Create bucket (--name)
devskin storage get ID                        Show bucket details
devskin storage delete ID                     Delete bucket
```

Aliases: `s3`

### Volumes (EBS)

```
devskin volume list                           List volumes
devskin volume create                         Create volume (--name, --size, --type)
devskin volume get ID                         Show volume details
devskin volume attach VOLUME_ID INSTANCE_ID   Attach volume to instance
devskin volume detach VOLUME_ID               Detach volume
devskin volume delete ID                      Delete volume
```

Aliases: `vol`

### Snapshots

```
devskin snapshot list                         List snapshots
devskin snapshot create                       Create snapshot (--volume, --name)
devskin snapshot delete ID                    Delete snapshot
```

Aliases: `snap`

### Images (AMI)

```
devskin image list                            List images
devskin image get ID                          Show image details
```

Aliases: `ami`

### VPC

```
devskin vpc list                              List VPCs
devskin vpc create                            Create VPC (--name, --cidr)
devskin vpc get ID                            Show VPC details
devskin vpc delete ID                         Delete VPC
```

### Subnets

```
devskin subnet list                           List subnets
devskin subnet create                         Create subnet (--name, --vpc, --cidr)
devskin subnet get ID                         Show subnet details
devskin subnet delete ID                      Delete subnet
```

### Elastic IP

```
devskin elastic-ip list                       List elastic IPs
devskin elastic-ip allocate                   Allocate elastic IP
devskin elastic-ip release ID                 Release elastic IP
devskin elastic-ip associate                  Associate elastic IP (--eip, --instance)
devskin elastic-ip disassociate               Disassociate elastic IP (--eip)
```

Aliases: `eip`

### Security Groups

```
devskin sg list                               List security groups
devskin sg create                             Create security group (--name, --vpc)
devskin sg get ID                             Show security group details
devskin sg delete ID                          Delete security group
```

Aliases: `security-group`

### Load Balancers

```
devskin lb list                               List load balancers
devskin lb create                             Create load balancer (--name, --type)
devskin lb get ID                             Show load balancer details
devskin lb delete ID                          Delete load balancer
```

Aliases: `load-balancer`

### CDN (CloudFront)

```
devskin cdn list                              List distributions
devskin cdn create                            Create distribution (--origin)
devskin cdn get ID                            Show distribution details
devskin cdn delete ID                         Delete distribution
devskin cdn invalidate ID                     Invalidate cache (--paths)
devskin cdn toggle ID                         Enable/disable distribution
```

Aliases: `cloudfront`

### Serverless Functions (Lambda)

```
devskin function list                         List functions
devskin function create                       Create function (--name, --runtime)
devskin function get ID                       Show function details
devskin function invoke ID                    Invoke function (--payload)
devskin function delete ID                    Delete function
```

Aliases: `lambda`, `fn`

### Kubernetes (EKS)

```
devskin k8s list                              List clusters
devskin k8s create                            Create cluster (--name, --version)
devskin k8s get ID                            Show cluster details
devskin k8s delete ID                         Delete cluster
```

Aliases: `kubernetes`, `eks`

### K8s Pods

```
devskin pod list [--namespace NS]             List pods
devskin pod get ID                            Show pod details
devskin pod logs ID [--tail N]                Get pod logs
devskin pod delete ID                         Delete pod
```

Aliases: `pods`

### K8s Services

```
devskin k8s-svc list [--namespace NS]         List K8s services
devskin k8s-svc create                        Create service (--name, --namespace, --type)
devskin k8s-svc get ID                        Show service details
devskin k8s-svc delete ID                     Delete service
```

Aliases: `k8s-service`

### DNS (Route53)

```
devskin dns list                              List hosted zones
devskin dns create                            Create zone (--name)
devskin dns get ID                            Show zone details
devskin dns delete ID                         Delete zone
devskin dns records ZONE_ID                   List records
devskin dns add-record ZONE_ID                Add record (--name, --type, --value)
devskin dns del-record ZONE_ID RECORD_ID      Delete record
```

Aliases: `route53`

### Monitoring -- Alarms

```
devskin alarm list                            List alarms
devskin alarm create                          Create alarm (--name, --metric, --threshold)
devskin alarm get ID                          Show alarm details
devskin alarm toggle ID                       Toggle alarm
devskin alarm delete ID                       Delete alarm
```

### Monitoring -- Logs

```
devskin log list                              List log groups
devskin log create                            Create log group (--name)
devskin log delete ID                         Delete log group
devskin log export ID                         Export logs (--from, --to)
```

### Certificates

```
devskin cert list                             List certificates
devskin cert request                          Request certificate (--domain, [--sans])
devskin cert get ID                           Show certificate details
devskin cert renew ID                         Renew certificate
devskin cert delete ID                        Delete certificate
```

Aliases: `certificate`

### Key Pairs

```
devskin keypair list                          List key pairs
devskin keypair create                        Create key pair (--name)
devskin keypair delete ID                     Delete key pair
```

Aliases: `key-pair`

### IAM

```
devskin iam users list                        List IAM users
devskin iam users create                      Create IAM user (--name, --email)
devskin iam users delete ID                   Delete IAM user
devskin iam groups list                       List IAM groups
devskin iam groups create                     Create IAM group (--name)
devskin iam groups delete ID                  Delete IAM group
devskin iam roles list                        List IAM roles
devskin iam roles create                      Create IAM role (--name)
devskin iam roles delete ID                   Delete IAM role
devskin iam policies list                     List IAM policies
devskin iam policies create                   Create policy (--name)
devskin iam policies delete ID                Delete policy
```

### Containers (ECS)

```
devskin container list                        List container services
devskin container create                      Create service (--name, --image)
devskin container get ID                      Show service details
devskin container delete ID                   Delete service
devskin container deploy ID                   Deploy/update service
devskin container restart ID                  Restart service
```

Aliases: `containers`, `ecs`

### CI/CD Pipelines

```
devskin cicd pipelines list                   List pipelines
devskin cicd pipelines create                 Create pipeline (--name, --repo)
devskin cicd pipelines get ID                 Show pipeline details
devskin cicd trigger ID                       Trigger pipeline
devskin cicd logs ID                          Get pipeline logs
devskin cicd builds list                      List builds
devskin cicd deployments list                 List deployments
```

Aliases: `pipeline`, `pipelines`

### Git Repositories

```
devskin git repos list                        List repositories
devskin git repos create                      Create repo (--name)
devskin git repos get ID                      Show repo details
devskin git repos delete ID                   Delete repo
devskin git branches ID                       List branches
devskin git commits ID                        List commits
devskin git credentials                       Show Git credentials
```

Aliases: `gitea`

### SQS (Message Queues)

```
devskin sqs list                              List queues
devskin sqs create                            Create queue (--name, [--type standard|fifo])
devskin sqs get ID                            Show queue details
devskin sqs send ID                           Send message (--body)
devskin sqs receive ID                        Receive messages
devskin sqs purge ID                          Purge queue
devskin sqs delete ID                         Delete queue
```

Aliases: `queue`, `queues`

### SNS (Notifications)

```
devskin sns list                              List topics
devskin sns create                            Create topic (--name)
devskin sns get ID                            Show topic details
devskin sns publish ID                        Publish message (--message)
devskin sns delete ID                         Delete topic
```

Aliases: `topic`, `topics`

### EventBridge

```
devskin eventbridge buses list                List event buses
devskin eventbridge buses create              Create event bus (--name)
devskin eventbridge buses delete ID           Delete event bus
devskin eventbridge rules list                List event rules
devskin eventbridge rules create              Create event rule (--name, --bus, --pattern)
devskin eventbridge rules delete ID           Delete event rule
```

Aliases: `eb`

### DynamoDB

```
devskin dynamodb list                         List tables
devskin dynamodb create                       Create table (--name, --pk, [--pk-type S|N])
devskin dynamodb get ID                       Show table details
devskin dynamodb items ID                     List items
devskin dynamodb delete ID                    Delete table
```

Aliases: `dynamo`

### MongoDB

```
devskin mongodb list                          List clusters
devskin mongodb create                        Create cluster (--name, [--tier], [--region])
devskin mongodb get ID                        Show cluster details
devskin mongodb delete ID                     Delete cluster
```

Aliases: `mongo`

### Redis (ElastiCache)

```
devskin redis list                            List clusters
devskin redis create                          Create cluster (--name, [--node-type], [--nodes])
devskin redis get ID                          Show cluster details
devskin redis delete ID                       Delete cluster
```

Aliases: `elasticache`

### EFS (Elastic File System)

```
devskin efs list                              List file systems
devskin efs create                            Create file system (--name, [--performance])
devskin efs get ID                            Show file system details
devskin efs delete ID                         Delete file system
```

### Glacier (Archive Storage)

```
devskin glacier list                          List vaults
devskin glacier create                        Create vault (--name)
devskin glacier get ID                        Show vault details
devskin glacier delete ID                     Delete vault
```

### Artifacts

```
devskin artifacts list                        List artifact repositories
devskin artifacts create                      Create repo (--name, --format)
devskin artifacts delete ID                   Delete repo
devskin artifacts packages ID                 List packages
```

Aliases: `artifact`

### Container Registry (ECR)

```
devskin registry list                         List repositories
devskin registry create                       Create repo (--name)
devskin registry get ID                       Show repo details
devskin registry images ID                    List images
devskin registry delete ID                    Delete repo
```

Aliases: `ecr`

### API Gateway

```
devskin api-gateway list                      List API gateways
devskin api-gateway create                    Create gateway (--name, [--type REST|HTTP])
devskin api-gateway get ID                    Show gateway details
devskin api-gateway deploy ID                 Deploy gateway
devskin api-gateway delete ID                 Delete gateway
```

Aliases: `apigw`

### Secrets Manager

```
devskin secrets list                          List secrets
devskin secrets create                        Create secret (--name, --value)
devskin secrets get ID                        Show secret details
devskin secrets value ID                      Get secret value
devskin secrets rotate ID                     Rotate secret
devskin secrets delete ID                     Delete secret
```

Aliases: `secret`

### Auto Scaling

```
devskin autoscaling list                      List auto scaling groups
devskin autoscaling create                    Create group (--name, --min, --max, --desired)
devskin autoscaling get ID                    Show group details
devskin autoscaling delete ID                 Delete group
```

Aliases: `asg`

### Support

```
devskin support list                          List tickets
devskin support create                        Create ticket (--subject, --body, [--priority])
devskin support get ID                        Show ticket details
devskin support reply ID                      Reply to ticket (--body)
devskin support close ID                      Close ticket
```

Aliases: `ticket`, `tickets`

### Marketplace

```
devskin marketplace list                      List products
devskin marketplace get ID                    Show product details
devskin marketplace subscribe ID              Subscribe to product
devskin marketplace unsubscribe ID            Unsubscribe from product
devskin marketplace subscriptions             List active subscriptions
```

### Consumption / Cost

```
devskin consumption summary                   Usage summary
devskin consumption trends                    Cost trends
devskin consumption forecast                  Cost forecast
devskin consumption prices                    Service prices
```

Aliases: `cost`

### Billing

```
devskin billing subscription                  Show subscription
devskin billing usage                         Show usage
devskin billing invoices                      List invoices
```

### AI Services

```
devskin ai models                             List AI models
devskin ai chat                               Chat with AI (--model, --message)
devskin ai usage                              Show AI usage stats
```

### Admin -- Zones

```
devskin zone list                             List infrastructure zones
devskin zone create                           Create zone (--slug, --name)
devskin zone get ID                           Show zone details
devskin zone delete ID                        Delete zone
```

### Settings -- API Keys

```
devskin apikey list                            List API keys
devskin apikey create                           Create API key (--name)
devskin apikey delete ID                        Delete API key
devskin apikey regenerate ID                    Regenerate API key
```

Aliases: `api-key`

## Examples

### Deploy a web application

```bash
# Create a compute instance
devskin compute create --name web-app --type t3.small --image ami-ubuntu-22

# Create a database
devskin db create --name web-db --engine postgres --class db.t3.micro --storage 20

# Create a storage bucket for assets
devskin storage create --name web-assets

# Set up a load balancer
devskin lb create --name web-lb --type application

# Request an SSL certificate
devskin cert request --domain myapp.com --sans "*.myapp.com"
```

### Manage infrastructure with SSH

```bash
# List your instances
devskin compute list

# SSH into an instance
devskin compute ssh i-abc123

# Stop an instance for maintenance
devskin compute stop i-abc123

# Start it back up
devskin compute start i-abc123
```

### Container deployment workflow

```bash
# Create a container registry
devskin registry create --name my-app

# Create a container service
devskin container create --name api-service --image my-app:latest --cpu 256 --memory 512

# Deploy an update
devskin container deploy svc-12345
```

### CI/CD pipeline

```bash
# Create a pipeline from a Git repo
devskin cicd pipelines create --name deploy-prod --repo repo-12345

# Trigger a build
devskin cicd trigger pipeline-12345

# View build logs
devskin cicd logs build-12345
```

### Kubernetes workflow

```bash
# Create a K8s cluster
devskin k8s create --name prod-cluster --version 1.28

# List pods
devskin pod list --namespace default

# Get pod logs
devskin pod logs pod-12345 --tail 100

# Create a K8s service
devskin k8s-svc create --name api --namespace default --type LoadBalancer
```

### Secrets and configuration

```bash
# Store a secret
devskin secrets create --name DB_PASSWORD --value "s3cur3p@ss"

# Retrieve a secret value
devskin secrets value secret-12345

# Rotate a secret
devskin secrets rotate secret-12345
```

### Cost management

```bash
# View usage summary
devskin consumption summary

# Check cost trends
devskin consumption trends

# Get cost forecast
devskin consumption forecast
```

## Configuration

The CLI stores configuration in `~/.devskin/config`. The config file contains:

- `api_url` -- The API endpoint
- `token` -- Your authentication token

The config directory is created with `700` permissions and the config file with `600` for security.

## License

MIT License -- see [LICENSE](LICENSE) for details.
