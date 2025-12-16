#!/usr/bin/env elixir

# Simple test to validate reflection system works
Mix.install([
  {:jason, "~> 1.4"}
])

# Test domain config
test_domain_config = %{
  "domain" => "test_domain",
  "display_name" => "Test Domain",
  "description" => "Test domain for reflection",
  "signals_fields" => ["request_type", "priority", "status"],
  "patterns" => [
    %{
      "id" => "test_pattern",
      "outcome" => "process_request",
      "score" => 0.7,
      "summary" => "Test pattern",
      "use_when" => [%{"field" => "request_type", "op" => "equals", "value" => "test"}],
      "avoid_when" => [],
      "typical_use_cases" => ["Testing"]
    }
  ]
}

IO.puts("🧪 Testing reflection system with simple domain config...")
IO.puts("Domain config: #{inspect(test_domain_config)}")

# Test reflection options
reflection_options = %{
  max_iterations: 1,
  quality_threshold: 0.5,
  timeout_ms: 30_000,
  enable_progress_tracking: false,
  enable_cancellation: false
}

IO.puts("Reflection options: #{inspect(reflection_options)}")

try do
  # This would test the reflection system if we could load the modules
  IO.puts("✅ Simple reflection test setup complete")
  IO.puts("Note: This is a standalone test - actual reflection would require the full application context")
rescue
  error ->
    IO.puts("❌ Error in simple test: #{inspect(error)}")
end
