#!/bin/bash

# Docker setup script for Decision Engine
set -e

echo "🐳 Setting up Decision Engine with Docker..."

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Create necessary directories
echo "📁 Creating necessary directories..."
mkdir -p priv/static/uploads
mkdir -p tmp

# Set permissions
chmod 755 priv/static/uploads

# Build and start the application
echo "🔨 Building Docker image..."
docker-compose -f docker-compose.dev.yml build

echo "🚀 Starting Decision Engine..."
docker-compose -f docker-compose.dev.yml up -d

echo "⏳ Waiting for application to start..."
sleep 10

# Check if the application is running
if curl -f http://localhost:4000/ > /dev/null 2>&1; then
    echo "✅ Decision Engine is running successfully!"
    echo "🌐 Access the application at: http://localhost:4000"
    echo ""
    echo "📋 Useful commands:"
    echo "  - View logs: docker-compose -f docker-compose.dev.yml logs -f"
    echo "  - Stop: docker-compose -f docker-compose.dev.yml down"
    echo "  - Restart: docker-compose -f docker-compose.dev.yml restart"
    echo "  - Shell access: docker-compose -f docker-compose.dev.yml exec decision_engine sh"
else
    echo "❌ Application failed to start. Check logs with:"
    echo "docker-compose -f docker-compose.dev.yml logs"
fi