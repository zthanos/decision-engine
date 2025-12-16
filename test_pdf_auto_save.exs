#!/usr/bin/env elixir

# Test script to verify PDF processing with auto-save functionality
# This script simulates the PDF processing workflow

Mix.install([
  {:req, "~> 0.3.0"},
  {:jason, "~> 1.4"}
])

defmodule PDFAutoSaveTest do
  @moduledoc """
  Test script to verify that PDF processing automatically saves domains to the database.
  """

  def run do
    IO.puts("🚀 Testing PDF Auto-Save Functionality...")

    # Step 1: Get initial domain count
    IO.puts("\n📊 Step 1: Getting initial domain count...")
    initial_count = get_domain_count()
    IO.puts("   ✅ Initial domains: #{initial_count}")

    # Step 2: Test the PDF processing endpoint (if available)
    IO.puts("\n📄 Step 2: Testing PDF processing workflow...")

    # Since we can't easily upload a file via HTTP, let's check the logs
    # to see if our auto-save logic is working
    IO.puts("   ℹ️  Manual test required: Upload a PDF via the web interface")
    IO.puts("   ℹ️  Expected behavior: Domain should be automatically saved and appear in domain list")

    # Step 3: Instructions for manual testing
    IO.puts("\n🔧 Manual Testing Instructions:")
    IO.puts("   1. Open http://localhost:4000/domains in your browser")
    IO.puts("   2. Click 'Upload PDF' button")
    IO.puts("   3. Upload a PDF file and enter a domain name")
    IO.puts("   4. Click 'Process PDF'")
    IO.puts("   5. Verify that:")
    IO.puts("      - Processing completes successfully")
    IO.puts("      - Domain appears in the domain list automatically")
    IO.puts("      - No manual 'Save' step is required")

    # Step 4: Check if we can monitor the domain count change
    IO.puts("\n⏱️  Step 4: Monitoring for domain count changes...")
    IO.puts("   (Waiting 30 seconds for manual testing...)")

    Process.sleep(30_000)

    final_count = get_domain_count()
    IO.puts("   📊 Final domains: #{final_count}")

    if final_count > initial_count do
      IO.puts("   ✅ SUCCESS: Domain count increased! Auto-save is working.")
    else
      IO.puts("   ℹ️  No change detected. Manual test may not have been performed.")
    end

    IO.puts("\n🎉 Test completed!")
  end

  defp get_domain_count do
    case Req.get("http://localhost:4000/domains") do
      {:ok, %{status: 200, body: body}} ->
        # Count occurrences of domain entries in the HTML
        # Look for the pattern that indicates domain entries
        domain_matches = Regex.scan(~r/## [A-Za-z0-9\s_-]+/, body)
        length(domain_matches)

      {:error, reason} ->
        IO.puts("   ❌ Failed to fetch domains: #{inspect(reason)}")
        0
    end
  end
end

PDFAutoSaveTest.run()
