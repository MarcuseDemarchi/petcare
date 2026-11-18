package config

import (
	"context"
	"log"
	"os"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/lambda"
	"github.com/aws/aws-sdk-go-v2/service/sns"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
)

type Config struct {
	Port               string
	MongoURI           string
	MongoDatabase      string
	AWSRegion          string
	SQSQueueURL        string
	SNSTopicARN        string
	LambdaFunctionName string
}

type AWSClients struct {
	SQS    *sqs.Client
	SNS    *sns.Client
	Lambda *lambda.Client
}

func Load() *Config {
	return &Config{
		Port:               getEnv("APP_PORT", "8080"),
		MongoURI:           getEnv("MONGO_URI", "mongodb://localhost:27017/petcare"),
		MongoDatabase:      getEnv("MONGO_DATABASE", "petcare"),
		AWSRegion:          getEnv("AWS_REGION", "us-east-1"),
		SQSQueueURL:        getEnv("SQS_QUEUE_URL", ""),
		SNSTopicARN:        getEnv("SNS_TOPIC_ARN", ""),
		LambdaFunctionName: getEnv("LAMBDA_FUNCTION_NAME", "petcare-cloud-processar-agendamento"),
	}
}

// NewAWSClients usa a cadeia padrão de credenciais do SDK.
// Em produção as credenciais vêm do Instance Profile da EC2 (temporárias, via IMDSv2):
// nenhuma chave de acesso permanente é configurada na aplicação.
func NewAWSClients(cfg *Config) *AWSClients {
	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background(),
		awsconfig.WithRegion(cfg.AWSRegion),
	)
	if err != nil {
		log.Printf("Aviso: falha ao carregar configuração AWS: %v", err)
		return &AWSClients{}
	}

	return &AWSClients{
		SQS:    sqs.NewFromConfig(awsCfg),
		SNS:    sns.NewFromConfig(awsCfg),
		Lambda: lambda.NewFromConfig(awsCfg),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
