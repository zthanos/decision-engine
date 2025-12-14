@echo off
REM Docker setup script for Decision Engine (Windows)

echo 🐳 Setting up Decision Engine with Docker...

REM Check if Docker is installed
docker --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ Docker is not installed. Please install Docker Desktop first.
    pause
    exit /b 1
)

REM Check if Docker Compose is available
docker compose version >nul 2>&1
if %errorlevel% neq 0 (
    docker-compose --version >nul 2>&1
    if %errorlevel% neq 0 (
        echo ❌ Docker Compose is not available. Please install Docker Compose.
        pause
        exit /b 1
    )
)

REM Create necessary directories
echo 📁 Creating necessary directories...
if not exist "priv\static\uploads" mkdir priv\static\uploads
if not exist "tmp" mkdir tmp

REM Build and start the application
echo 🔨 Building Docker image...
docker-compose -f docker-compose.dev.yml build

echo 🚀 Starting Decision Engine...
docker-compose -f docker-compose.dev.yml up -d

echo ⏳ Waiting for application to start...
timeout /t 15 /nobreak >nul

REM Check if the application is running
curl -f http://localhost:4000/ >nul 2>&1
if %errorlevel% equ 0 (
    echo ✅ Decision Engine is running successfully!
    echo 🌐 Access the application at: http://localhost:4000
    echo.
    echo 📋 Useful commands:
    echo   - View logs: docker-compose -f docker-compose.dev.yml logs -f
    echo   - Stop: docker-compose -f docker-compose.dev.yml down
    echo   - Restart: docker-compose -f docker-compose.dev.yml restart
    echo   - Shell access: docker-compose -f docker-compose.dev.yml exec decision_engine sh
) else (
    echo ❌ Application failed to start. Check logs with:
    echo docker-compose -f docker-compose.dev.yml logs
)

pause