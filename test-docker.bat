@echo off
echo Testing Docker setup for Decision Engine...

REM Test if Docker is available
docker --version
if %errorlevel% neq 0 (
    echo Docker is not available
    exit /b 1
)

REM Test if we can build the image
echo Building test image...
docker build -t decision-engine-test .

if %errorlevel% equ 0 (
    echo ✅ Docker image built successfully!
    echo You can now run: docker-compose -f docker-compose.dev.yml up
) else (
    echo ❌ Failed to build Docker image
)

pause