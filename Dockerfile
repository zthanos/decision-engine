# Use the official Elixir image as base
FROM elixir:1.19.2-alpine

# Install system dependencies including PDF processing tools
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    python3 \
    py3-pip \
    poppler-utils \
    imagemagick \
    ghostscript \
    curl \
    bash

# Install Python PDF processing libraries
RUN pip3 install --break-system-packages PyPDF2 pdfplumber

# Set working directory
WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./

# Install Elixir dependencies
RUN mix deps.get

# Copy assets package files
COPY assets/package*.json assets/
RUN cd assets && npm install

# Copy the rest of the application
COPY . .

# Setup and build assets using Phoenix's asset pipeline
RUN mix assets.setup
RUN mix assets.build

# Compile the application
RUN mix compile

# Create uploads directory
RUN mkdir -p priv/static/uploads

# Expose port
EXPOSE 4000

# Set environment variables
ENV MIX_ENV=dev
ENV PHX_HOST=localhost
ENV PHX_PORT=4000

# Start the application
CMD ["mix", "phx.server"]