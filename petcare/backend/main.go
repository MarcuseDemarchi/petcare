package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"

	"petcare-backend/config"
	"petcare-backend/handlers"
)

// Version é injetada no build pela pipeline (-ldflags "-X main.Version=<commit>").
var Version = "dev"

func main() {
	cfg := config.Load()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	mongoClient, err := mongo.Connect(ctx, options.Client().ApplyURI(cfg.MongoURI))
	if err != nil {
		log.Fatalf("Falha ao configurar cliente MongoDB: %v", err)
	}
	defer func() { _ = mongoClient.Disconnect(context.Background()) }()

	db := mongoClient.Database(cfg.MongoDatabase)
	awsClients := config.NewAWSClients(cfg)
	h := handlers.New(db, awsClients, cfg)

	r := NewRouter(h, func(ctx context.Context) error { return mongoClient.Ping(ctx, nil) }, Version)

	srv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	go func() {
		log.Printf("PetCare Backend %s iniciando na porta %s", Version, cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Erro ao iniciar servidor: %v", err)
		}
	}()

	// Encerramento gracioso (usado pelo CodeDeploy no ApplicationStop)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("Encerrando servidor...")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutdownCancel()
	_ = srv.Shutdown(shutdownCtx)
}
