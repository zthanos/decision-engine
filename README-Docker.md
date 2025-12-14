# Decision Engine - Docker Setup

This guide explains how to run the Decision Engine application using Docker, which includes all necessary PDF processing tools.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed
- [Docker Compose](https://docs.docker.com/compose/install/) installed

## Quick Start

### Option 1: Automated Setup (Recommended)

**Windows:**
```cmd
scripts\docker-setup.bat
```

**Linux/Mac:**
```bash
chmod +x scripts/docker-setup.sh
./scripts/docker-setup.sh
```

### Option 2: Manual Setup

1. **Build and start the application:**
   ```bash
   docker-compose -f docker-compose.dev.yml up --build
   ```

2. **Access the application:**
   Open your browser and go to [http://localhost:4000](http://localhost:4000)

## Docker Configurations

### Development Mode (Recommended for local development)
```bash
# Start with live code reloading
docker-compose -f docker-compose.dev.yml up

# Build and start
docker-compose -f docker-compose.dev.yml up --build

# Run in background
docker-compose -f docker-compose.dev.yml up -d
```

### Production Mode
```bash
# Start production version
docker-compose -f docker-compose.prod.yml up --build
```

## Included PDF Processing Tools

The Docker image includes all necessary tools for PDF processing:

- **poppler-utils** - Provides `pdftotext` command for text extraction
- **Python 3** with **PyPDF2** and **pdfplumber** - Alternative PDF processing libraries
- **ImageMagick** - Image processing capabilities
- **Ghostscript** - PostScript and PDF manipulation

## Environment Variables

You can configure the application using environment variables:

```bash
# Create a .env file
cat > .env << EOF
OPENAI_API_KEY=your_openai_key_here
ANTHROPIC_API_KEY=your_anthropic_key_here
PHX_HOST=0.0.0.0
PHX_PORT=4000
EOF
```

## Useful Commands

### View Application Logs
```bash
docker-compose -f docker-compose.dev.yml logs -f decision_engine
```

### Access Container Shell
```bash
docker-compose -f docker-compose.dev.yml exec decision_engine sh
```

### Stop the Application
```bash
docker-compose -f docker-compose.dev.yml down
```

### Restart the Application
```bash
docker-compose -f docker-compose.dev.yml restart
```

### Rebuild the Image
```bash
docker-compose -f docker-compose.dev.yml build --no-cache
```

## Testing PDF Processing

Once the application is running:

1. Navigate to [http://localhost:4000/domains](http://localhost:4000/domains)
2. Click "Generate Domain from PDF"
3. Upload a PDF file
4. The system should successfully extract text using the included tools

## Troubleshooting

### Application Won't Start
```bash
# Check logs
docker-compose -f docker-compose.dev.yml logs

# Rebuild image
docker-compose -f docker-compose.dev.yml build --no-cache
```

### PDF Processing Issues
```bash
# Check if PDF tools are available
docker-compose -f docker-compose.dev.yml exec decision_engine pdftotext -v
docker-compose -f docker-compose.dev.yml exec decision_engine python3 -c "import PyPDF2; print('PyPDF2 available')"
```

### Port Already in Use
If port 4000 is already in use, modify the port mapping in `docker-compose.dev.yml`:
```yaml
ports:
  - "4001:4000"  # Use port 4001 instead
```

## File Persistence

- **Uploaded files** are stored in a Docker volume (`uploads_data`)
- **Application code** is mounted for development (live reloading)
- **Dependencies** are cached in Docker volumes for faster rebuilds

## Production Deployment

For production deployment:

1. Use the production configuration:
   ```bash
   docker-compose -f docker-compose.prod.yml up -d
   ```

2. Set environment variables:
   ```bash
   export SECRET_KEY_BASE=$(mix phx.gen.secret)
   export OPENAI_API_KEY=your_production_key
   ```

3. Consider using a reverse proxy (nginx) and SSL certificates for HTTPS.

## Development Tips

- The development configuration mounts your source code, so changes are reflected immediately
- Dependencies are cached in Docker volumes for faster rebuilds
- Use `docker-compose -f docker-compose.dev.yml exec decision_engine iex -S mix` for interactive Elixir shell

## Support

If you encounter issues:

1. Check the logs: `docker-compose -f docker-compose.dev.yml logs`
2. Verify Docker installation: `docker --version && docker-compose --version`
3. Ensure ports are available: `netstat -an | grep 4000`
4. Try rebuilding: `docker-compose -f docker-compose.dev.yml build --no-cache`