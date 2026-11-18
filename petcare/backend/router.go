package main

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"

	"petcare-backend/handlers"
	"petcare-backend/middleware"
)

// PingFunc testa a conectividade com o banco (injetada para facilitar testes).
type PingFunc func(ctx context.Context) error

// NewRouter monta todas as rotas HTTP da API.
func NewRouter(h *handlers.Handler, ping PingFunc, version string) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	// Apenas o proxy local (nginx) e o ALB são confiáveis para X-Forwarded-For.
	_ = r.SetTrustedProxies([]string{"127.0.0.1", "10.20.0.0/16"})
	r.Use(cors.New(cors.Config{
		AllowOrigins:     []string{"*"},
		AllowMethods:     []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowHeaders:     []string{"Origin", "Content-Type"},
		ExposeHeaders:    []string{"Content-Length"},
		AllowCredentials: false,
		MaxAge:           12 * time.Hour,
	}))
	r.Use(middleware.SecurityHeaders())
	r.Use(middleware.Logger())

	// Liveness: usado pelo health check do ALB / Target Group.
	r.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "petcare-backend", "version": version})
	})

	// Readiness: verifica também o MongoDB (usado no ValidateService do CodeDeploy).
	r.GET("/health/ready", func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 3*time.Second)
		defer cancel()
		if err := ping(ctx); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"status": "degraded", "database": "indisponivel"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ok", "database": "ok", "version": version})
	})

	api := r.Group("/api")
	{
		api.GET("/version", func(c *gin.Context) {
			c.JSON(http.StatusOK, gin.H{"version": version})
		})

		// Pets
		api.GET("/pets", h.ListPets)
		api.POST("/pets", h.CreatePet)
		api.GET("/pets/:id", h.GetPet)
		api.PUT("/pets/:id", h.UpdatePet)
		api.DELETE("/pets/:id", h.DeletePet)

		// Agendamentos
		api.GET("/agendamentos", h.ListAgendamentos)
		api.POST("/agendamentos", h.CreateAgendamento)
		api.GET("/agendamentos/:id", h.GetAgendamento)
		api.PUT("/agendamentos/:id/status", h.UpdateStatusAgendamento)

		// Clientes
		api.GET("/clientes", h.ListClientes)
		api.POST("/clientes", h.CreateCliente)

		// Serviços
		api.GET("/servicos", h.ListServicos)

		// Estatísticas calculadas no MongoDB
		api.GET("/stats", h.GetStats)
	}

	return r
}
