/*
 * (C) Copyright IBM Corp. 2021
 *
 * SPDX-License-Identifier: Apache-2.0
 */

package healthcheck

import (
	configPkg "github.com/Alvearie/hri-mgmt-api/common/config"
	"github.com/Alvearie/hri-mgmt-api/common/elastic"
	"github.com/Alvearie/hri-mgmt-api/common/kafka"
	"github.com/Alvearie/hri-mgmt-api/common/logwrapper"
	"github.com/Alvearie/hri-mgmt-api/common/response"
	"github.com/elastic/go-elasticsearch/v7"
	"github.com/labstack/echo/v4"
	"net/http"
)

type Handler interface {
	Healthcheck(echo.Context) error
}

// This struct is designed to make unit testing easier. It has function references for the calls to backend
// logic and other methods that reach out to external services like creating the Kafka partition reader.
type theHandler struct {
	config                    configPkg.Config
	partitionReaderFromConfig func(config configPkg.Config) (kafka.PartitionReader, error)
	healthcheck               func(string, *elasticsearch.Client, kafka.PartitionReader) (int, *response.ErrorDetail)
}

func NewHandler(config configPkg.Config) Handler {
	return &theHandler{
		config: config,
		partitionReaderFromConfig: func(c configPkg.Config) (kafka.PartitionReader, error) {
			return kafka.ConnectionFromConfig(c)
		},
		healthcheck: Get,
	}
}

func (h *theHandler) Healthcheck(c echo.Context) error {
	//get Logger instance
	requestId := c.Response().Header().Get(echo.HeaderXRequestID)
	prefix := "healthcheck/handler"
	var logger = logwrapper.GetMyLogger(requestId, prefix)
	logger.Debug("Start Healthcheck Handler")

	esClient, err := elastic.ClientFromConfig(h.config)
	if err != nil {
		logger.Errorln(err.Error())
		return c.JSON(http.StatusInternalServerError, response.NewErrorDetail(requestId, err.Error()))
	}

	partitionReader, err := h.partitionReaderFromConfig(h.config)
	if err != nil {
		logger.Errorln(err.Error())
		return c.JSON(http.StatusInternalServerError, response.NewErrorDetail(requestId, err.Error()))
	}
	defer partitionReader.Close()

	code, errorDetail := h.healthcheck(requestId, esClient, partitionReader)
	if errorDetail != nil {
		return c.JSON(code, errorDetail)
	}
	return c.NoContent(code)
}
