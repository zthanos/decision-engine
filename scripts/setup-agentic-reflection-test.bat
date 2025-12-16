@echo off
echo Setting up Agentic Reflection Integration Test Environment...

REM Check if Docker is running
docker info >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ Docker is not running. Please start Docker Desktop.
    exit /b 1
)
echo ✅ Docker is running

REM Check for OpenAI API key
if defined OPENAI_API_KEY (
    echo ✅ OpenAI API key found - will use OpenAI for LLM integration
    echo 🔧 Configuring test environment for OpenAI...
    goto :run_test
)

REM Check if LM Studio is accessible
echo 🔍 Checking for LM Studio...
curl -s http://localhost:1234/v1/models >nul 2>&1
if %errorlevel% equ 0 (
    echo ✅ LM Studio is accessible at http://localhost:1234
    echo 🔧 Configuring test environment for LM Studio...
    goto :run_test
)

echo ❌ No LLM service available!
echo.
echo To run the agentic reflection test, you need either:
echo.
echo Option 1 - OpenAI API:
echo   Set environment variable: set OPENAI_API_KEY=your_api_key_here
echo.
echo Option 2 - LM Studio (Local):
echo   1. Download LM Studio from https://lmstudio.ai/
echo   2. Install and load a model (e.g., Llama 2 7B Chat)
echo   3. Start the local server:
echo      - Go to Local Server tab
echo      - Click "Start Server" 
echo      - Ensure it's running on port 1234
echo   4. Test with: curl http://localhost:1234/v1/models
echo.
echo Then run this script again.
pause
exit /b 1

:run_test
echo.
echo 🚀 Starting Agentic Reflection Integration Test...
echo.

REM Build and start Docker container
echo Building Docker container...
docker-compose -f docker-compose.dev.yml build
if %errorlevel% neq 0 (
    echo ❌ Failed to build Docker container
    exit /b 1
)

echo Starting Docker container...
docker-compose -f docker-compose.dev.yml up -d
if %errorlevel% neq 0 (
    echo ❌ Failed to start Docker container
    exit /b 1
)

echo Waiting for application to be ready...
timeout /t 20 /nobreak >nul

REM Check application health
curl -s http://localhost:4000/ >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ Application is not responding
    echo Checking logs...
    docker-compose -f docker-compose.dev.yml logs decision_engine
    exit /b 1
)

echo ✅ Application is ready

REM Run the agentic reflection test
echo.
echo 🧠 Running Agentic Reflection Integration Test...
echo This test will:
echo   1. Process PDF with LLM
echo   2. Create domain configuration  
echo   3. Run agentic reflection workflow
echo   4. Validate improvements and progress tracking
echo.

docker-compose -f docker-compose.dev.yml exec -T decision_engine mix test test/integration/docker_pdf_integration_test.exs -k "agentic reflection" --include integration

set TEST_RESULT=%errorlevel%

if %TEST_RESULT% equ 0 (
    echo.
    echo 🎉 Agentic Reflection Integration Test PASSED!
    echo ✅ PDF processing with LLM working
    echo ✅ Domain creation successful  
    echo ✅ Agentic reflection workflow functional
    echo ✅ Progress tracking validated
) else (
    echo.
    echo ❌ Agentic Reflection Integration Test FAILED
    echo Showing recent logs...
    docker-compose -f docker-compose.dev.yml logs --tail=50 decision_engine
)

echo.
echo Cleaning up...
docker-compose -f docker-compose.dev.yml down

exit /b %TEST_RESULT%