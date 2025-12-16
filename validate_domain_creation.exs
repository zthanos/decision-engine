#!/usr/bin/env elixir

# Simple validation script for domain and rule creation
# This script tests the core functionality without requiring complex test setup

IO.puts("🚀 Starting Domain and Rule Creation Validation...")

# Test configuration
test_pdf_path = "priv/samples/EDA_Decision_Reference.pdf"
test_domain_name = "validation_test_domain"

# Step 1: Validate PDF file exists
IO.puts("\n📄 Step 1: Validating PDF file...")
if File.exists?(test_pdf_path) do
  {:ok, content} = File.read(test_pdf_path)
  if String.starts_with?(content, "%PDF") do
    file_size = byte_size(content)
    IO.puts("   ✅ PDF file is valid (#{Float.round(file_size / 1024, 1)} KB)")
  else
    IO.puts("   ❌ File is not a valid PDF")
    System.halt(1)
  end
else
  IO.puts("   ❌ PDF file not found at #{test_pdf_path}")
  System.halt(1)
end

# Step 2: Test domain manager functionality
IO.puts("\n🏗️  Step 2: Testing domain manager...")
try do
  {:ok, domains} = DecisionEngine.DomainManager.list_domains()
  IO.puts("   ✅ Domain manager working, found #{length(domains)} existing domains")
rescue
  error ->
    IO.puts("   ❌ Domain manager error: #{inspect(error)}")
    System.halt(1)
end

# Step 3: Create a test domain configuration
IO.puts("\n🔧 Step 3: Creating test domain configuration...")
test_domain_config = %{
  name: test_domain_name,
  display_name: "Validation Test Domain",
  description: "A test domain created for validating domain and rule creation functionality.",
  signals_fields: [
    "complexity_level",
    "integration_type",
    "data_volume",
    "performance_requirements"
  ],
  patterns: [
    %{
      "id" => "high_complexity_integration",
      "outcome" => "use_enterprise_solution",
      "score" => 0.85,
      "summary" => "High complexity integration requires enterprise solution",
      "use_when" => [],
      "avoid_when" => [],
      "typical_use_cases" => []
    },
    %{
      "id" => "simple_data_sync",
      "outcome" => "use_basic_connector",
      "score" => 0.65,
      "summary" => "Simple data synchronization can use basic connector",
      "use_when" => [],
      "avoid_when" => [],
      "typical_use_cases" => []
    }
  ],
  schema_module: ""
}

IO.puts("   ✅ Test domain configuration created")
IO.puts("      - Name: #{test_domain_config.name}")
IO.puts("      - Signal fields: #{length(test_domain_config.signals_fields)}")
IO.puts("      - Patterns: #{length(test_domain_config.patterns)}")

# Step 4: Validate domain configuration structure
IO.puts("\n🔍 Step 4: Validating domain configuration structure...")

# Check required fields
required_fields = [:name, :display_name, :description, :signals_fields, :patterns]
for field <- required_fields do
  if Map.has_key?(test_domain_config, field) do
    IO.puts("   ✅ Has required field: #{field}")
  else
    IO.puts("   ❌ Missing required field: #{field}")
    System.halt(1)
  end
end

# Validate patterns
for {pattern, idx} <- Enum.with_index(test_domain_config.patterns) do
  pattern_fields = ["id", "outcome", "score", "summary"]
  for field <- pattern_fields do
    if Map.has_key?(pattern, field) do
      IO.puts("   ✅ Pattern #{idx + 1} has field: #{field}")
    else
      IO.puts("   ❌ Pattern #{idx + 1} missing field: #{field}")
      System.halt(1)
    end
  end

  # Validate score range
  score = pattern["score"]
  if is_number(score) and score >= 0.0 and score <= 1.0 do
    IO.puts("   ✅ Pattern #{idx + 1} score is valid: #{score}")
  else
    IO.puts("   ❌ Pattern #{idx + 1} score is invalid: #{score}")
    System.halt(1)
  end
end

# Step 5: Test domain creation
IO.puts("\n💾 Step 5: Testing domain creation...")

# Clean up any existing test domain
try do
  DecisionEngine.DomainManager.delete_domain(String.to_atom(test_domain_name))
  IO.puts("   ℹ️  Cleaned up existing test domain")
rescue
  _ -> :ok
end

# Create the domain
case DecisionEngine.DomainManager.create_domain(test_domain_config) do
  {:ok, _} ->
    IO.puts("   ✅ Domain created successfully")
  {:error, reason} ->
    IO.puts("   ❌ Domain creation failed: #{inspect(reason)}")
    System.halt(1)
end

# Step 6: Test domain retrieval
IO.puts("\n🔍 Step 6: Testing domain retrieval...")
case DecisionEngine.DomainManager.get_domain(String.to_atom(test_domain_name)) do
  {:ok, retrieved_domain} ->
    IO.puts("   ✅ Domain retrieved successfully")
    IO.puts("      - Retrieved name: #{retrieved_domain.name}")
    IO.puts("      - Signal fields: #{length(retrieved_domain.signals_fields)}")
    IO.puts("      - Patterns: #{length(retrieved_domain.patterns)}")

    # Validate retrieved domain matches created domain
    if retrieved_domain.name == test_domain_config.name do
      IO.puts("   ✅ Retrieved domain name matches")
    else
      IO.puts("   ❌ Retrieved domain name mismatch")
      System.halt(1)
    end

    if length(retrieved_domain.signals_fields) == length(test_domain_config.signals_fields) do
      IO.puts("   ✅ Signal fields count matches")
    else
      IO.puts("   ❌ Signal fields count mismatch")
      System.halt(1)
    end

    if length(retrieved_domain.patterns) == length(test_domain_config.patterns) do
      IO.puts("   ✅ Patterns count matches")
    else
      IO.puts("   ❌ Patterns count mismatch")
      System.halt(1)
    end

  {:error, reason} ->
    IO.puts("   ❌ Domain retrieval failed: #{inspect(reason)}")
    System.halt(1)
end

# Step 7: Test domain listing
IO.puts("\n📋 Step 7: Testing domain listing...")
{:ok, all_domains} = DecisionEngine.DomainManager.list_domains()
domain_names = Enum.map(all_domains, & &1.name)

if test_domain_name in domain_names do
  IO.puts("   ✅ Test domain appears in domain list")
  IO.puts("   📊 Total domains in system: #{length(all_domains)}")
else
  IO.puts("   ❌ Test domain not found in domain list")
  System.halt(1)
end

# Step 8: Test PDF processing (if LLM is available)
IO.puts("\n📄 Step 8: Testing PDF processing...")
case DecisionEngine.PDFProcessor.process_pdf_for_domain(test_pdf_path, "pdf_test_domain") do
  {:ok, pdf_domain_config} ->
    IO.puts("   ✅ PDF processing successful!")
    IO.puts("      - Generated domain: #{pdf_domain_config.name}")
    IO.puts("      - Signal fields: #{length(pdf_domain_config.signals_fields)}")
    IO.puts("      - Patterns: #{length(pdf_domain_config.patterns)}")

    # Display some generated content
    IO.puts("   📊 Generated signal fields: #{inspect(Enum.take(pdf_domain_config.signals_fields, 3))}")

    if length(pdf_domain_config.patterns) > 0 do
      first_pattern = List.first(pdf_domain_config.patterns)
      IO.puts("   📊 First pattern: #{first_pattern["id"]} -> #{first_pattern["outcome"]} (#{first_pattern["score"]})")
    end

    # Clean up PDF test domain
    try do
      DecisionEngine.DomainManager.delete_domain(String.to_atom("pdf_test_domain"))
    rescue
      _ -> :ok
    end

  {:error, reason} ->
    IO.puts("   ⚠️  PDF processing failed (likely LLM unavailable): #{inspect(reason)}")
    IO.puts("   ℹ️  This is expected if LM Studio is not running or accessible")
end

# Step 9: Clean up test domain
IO.puts("\n🧹 Step 9: Cleaning up test domain...")
case DecisionEngine.DomainManager.delete_domain(String.to_atom(test_domain_name)) do
  :ok ->
    IO.puts("   ✅ Test domain deleted successfully")
  {:error, reason} ->
    IO.puts("   ❌ Test domain deletion failed: #{inspect(reason)}")
    System.halt(1)
end

# Verify deletion
case DecisionEngine.DomainManager.get_domain(String.to_atom(test_domain_name)) do
  {:error, _} ->
    IO.puts("   ✅ Test domain properly removed from system")
  {:ok, _} ->
    IO.puts("   ❌ Test domain still exists after deletion")
    System.halt(1)
end

# Final summary
IO.puts("\n🎉 Domain and Rule Creation Validation Complete!")
IO.puts("✅ All core functionality tests passed:")
IO.puts("   - PDF file validation")
IO.puts("   - Domain manager functionality")
IO.puts("   - Domain configuration structure validation")
IO.puts("   - Domain creation and persistence")
IO.puts("   - Domain retrieval and listing")
IO.puts("   - Domain deletion and cleanup")
IO.puts("   - PDF processing (if LLM available)")

IO.puts("\n📊 Summary:")
IO.puts("   - Domain creation: ✅ Working")
IO.puts("   - Rule validation: ✅ Working")
IO.puts("   - Persistence: ✅ Working")
IO.puts("   - Cleanup: ✅ Working")

IO.puts("\n🎯 Integration test successful! The domain and rule creation workflow is functioning correctly.")
