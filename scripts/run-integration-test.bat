@echo off
echo Starting Docker Integration Test for Decision Engine...

REM Check if Docker is running
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ Docker is not running. Please start Docker Desktop.
    exit /b 1
)

echo ✅ Docker is running

REM Check if LM Studio is accessible
curl -s http://localhost:1234/v1/models >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ LM Studio is not accessible at http://localhost:1234
    echo Please ensure LM Studio is running and serving on port 1234
    echo You can start LM Studio and load a model, then try again
    pause
    exit /b 1
)

echo ✅ LM Studio is accessible

REM Build and start the Docker container
echo Building Docker container...
docker-compose -f docker-compose.dev.yml build

if %errorlevel% neq 0 (
    echo ❌ Failed to build Docker container
    exit /b 1
)

echo ✅ Docker container built successfully

REM Start the container with LM Studio configuration
echo Starting container with LM Studio configuration...
set LLM_PROVIDER=lmstudio
set LLM_ENDPOINT=http://host.docker.internal:1234
set LLM_MODEL=local-model
set DOCKER_TEST=true

docker-compose -f docker-compose.dev.yml up -d

if %errorlevel% neq 0 (
    echo ❌ Failed to start Docker container
    exit /b 1
)

echo ✅ Container started, waiting for application to be ready...

REM Wait for application to be ready
timeout /t 30 /nobreak >nul

REM Check application health
curl -s http://localhost:4000/ >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ Application is not responding
    echo Checking logs...
    docker-compose -f docker-compose.dev.yml logs decision_engine
    exit /b 1
)

echo ✅ Application is ready

REM Run the integration tests
echo Running integration tests...
docker-compose -f docker-compose.dev.yml exec -T decision_engine mix test test/integration/docker_pdf_integration_test.exs --include integration --include docker

set TEST_RESULT=%errorlevel%

REM Show logs if tests failed
if %TEST_RESULT% neq 0 (
    echo ❌ Integration tests failed
    echo Showing recent logs...
    docker-compose -f docker-compose.dev.yml logs --tail=50 decision_engine
) else (
    echo ✅ Integration tests passed successfully!
)

REM Cleanup
echo Stopping containers...
docker-compose -f docker-compose.dev.yml down

exit /b %TEST_RESULT%