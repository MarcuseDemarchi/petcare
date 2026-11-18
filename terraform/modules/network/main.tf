# =============================================================================
# Rede de produção - segmentação em 3 camadas (conforme diagrama):
#   Pública  (10.20.1.0/24 | 10.20.2.0/24)   -> ALB, NAT Gateways, GitLab
#   Privada  (10.20.11.0/24 | 10.20.12.0/24) -> EC2 de aplicação (sem IP público)
#   Isolada  (10.20.21.0/24)                 -> MongoDB (sem rota para internet)
# =============================================================================

locals {
  public_cidrs  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  private_cidrs = [cidrsubnet(var.vpc_cidr, 8, 11), cidrsubnet(var.vpc_cidr, 8, 12)]
  data_cidr     = cidrsubnet(var.vpc_cidr, 8, 21)
  az_labels     = ["a", "b"]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.name}-vpc" }
}

# Fecha o Security Group default (nada usa o SG default) - CIS AWS 5.4
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-sg-bloqueado" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

# ---------------------------------------------------------------- Sub-redes
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name = "${var.name}-publica-${local.az_labels[count.index]}"
    Tier = "publica"
  }
}

resource "aws_subnet" "private_app" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags = {
    Name = "${var.name}-privada-app-${local.az_labels[count.index]}"
    Tier = "aplicacao"
  }
}

resource "aws_subnet" "data" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data_cidr
  availability_zone = var.azs[0]
  tags = {
    Name = "${var.name}-isolada-dados-a"
    Tier = "dados"
  }
}

# ---------------------------------------------------------------- NAT (1 por zona)
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip-${local.az_labels[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-nat-${local.az_labels[count.index]}" }
  depends_on    = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------- Rotas
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-rt-publica" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Cada zona privada sai pelo NAT da própria zona (sem dependência entre AZs)
resource "aws_route_table" "private_app" {
  count  = 2
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
  tags = { Name = "${var.name}-rt-privada-app-${local.az_labels[count.index]}" }
}

resource "aws_route_table_association" "private_app" {
  count          = 2
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

# Sub-rede de dados: SOMENTE rota local + VPC endpoints. Sem 0.0.0.0/0.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-rt-isolada-dados" }
}

resource "aws_route_table_association" "data" {
  subnet_id      = aws_subnet.data.id
  route_table_id = aws_route_table.data.id
}

# ---------------------------------------------------------------- NACL da camada de dados
# Defesa em profundidade além do Security Group: a sub-rede isolada só aceita
# MongoDB vindo das sub-redes de aplicação e tráfego HTTPS de/para endpoints AWS.
resource "aws_network_acl" "data" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = [aws_subnet.data.id]
  tags       = { Name = "${var.name}-nacl-dados" }
}

resource "aws_network_acl_rule" "data_in_mongo" {
  count          = 2
  network_acl_id = aws_network_acl.data.id
  rule_number    = 100 + count.index
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.private_cidrs[count.index]
  from_port      = 27017
  to_port        = 27017
}

# Interface endpoints (SSM) ficam nesta sub-rede e são usados por toda a VPC
resource "aws_network_acl_rule" "data_in_endpoints" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 443
  to_port        = 443
}

# Respostas de HTTPS (S3 gateway endpoint / repositórios AL2023 / interface endpoints)
# (faixa dividida para não expor a porta 3389/RDP)
resource "aws_network_acl_rule" "data_in_ephemeral" {
  for_each       = { "200" = [1024, 3388], "201" = [3390, 65535] }
  network_acl_id = aws_network_acl.data.id
  rule_number    = tonumber(each.key)
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = each.value[0]
  to_port        = each.value[1]
}

# Respostas ao MongoDB e aos endpoints, somente para dentro da VPC
resource "aws_network_acl_rule" "data_out_ephemeral_vpc" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "data_out_https" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# ---------------------------------------------------------------- VPC Endpoints
# S3 (gateway, gratuito): MongoDB baixa o RPM espelhado e os pacotes do AL2023 sem internet.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private_app[*].id, [aws_route_table.data.id])
  tags              = { Name = "${var.name}-vpce-s3" }
}

data "aws_region" "current" {}

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-sg-vpc-endpoints"
  description = "HTTPS para os interface endpoints (SSM) a partir da VPC"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS da VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Respostas dentro da VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.name}-sg-vpc-endpoints" }
}

# SSM (Session Manager + Parameter Store) para a camada isolada: administração
# sem SSH e sem internet. Com Private DNS, toda a VPC usa estes endpoints.
resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(["ssm", "ssmmessages", "ec2messages"])
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.data.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${var.name}-vpce-${each.key}" }
}

# ---------------------------------------------------------------- Flow Logs (auditoria)
resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${var.flow_logs_bucket_arn}/vpc-flow-logs/"
  tags                 = { Name = "${var.name}-flow-logs" }
}
