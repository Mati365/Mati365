#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.4"}
])

defmodule GithubStarsUpdater do
  @moduledoc """
  Script to automatically update GitHub stars count in README.md.
  """

  @github_api_base "https://api.github.com"
  @readme_path "README.md"
  @owner "Mati365"

  def run do
    IO.puts("🚀 Starting stars update...")

    readme_content = File.read!(@readme_path)
    repos = extract_repos(readme_content)

    IO.puts("📦 Found #{length(repos)} repositories")

    stars_map = fetch_stars_for_repos(repos)
    updated_content =
      readme_content
      |> update_readme_with_stars(stars_map)
      |> sort_projects_in_sections(stars_map)
      |> update_top_projects_section(stars_map)

    if readme_content != updated_content do
      File.write!(@readme_path, updated_content)
      IO.puts("✅ README.md updated!")
      System.halt(0)
    else
      IO.puts("ℹ️  No changes in stars count")
      System.halt(0)
    end
  end

  defp extract_repos(content) do
    ~r/\[([^\]]+)\]\(https:\/\/github\.com\/#{@owner}\/([^\)]+)\)/
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [_name, repo] -> repo end)
    |> Enum.uniq()
  end

  defp fetch_stars_for_repos(repos) do
    repos
    |> Enum.map(fn repo ->
      stars = fetch_repo_stars(repo)

      IO.puts("  #{repo}: ⭐ #{stars}")
      Process.sleep(300)

      {repo, stars}
    end)
    |> Map.new()
  end

  defp fetch_repo_stars(repo) do
    url = "#{@github_api_base}/repos/#{@owner}/#{repo}"

    headers = %{
      "user-agent" => "Elixir-Stars-Updater",
      "accept" => "application/vnd.github.v3+json"
    }

    headers = case System.get_env("GITHUB_TOKEN") do
      nil -> headers
      token -> Map.put(headers, "authorization", "Bearer #{token}")
    end

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        Map.get(body, "stargazers_count", 0)

      {:ok, %{status: status}} ->
        IO.puts("⚠️  HTTP error #{status} for #{repo}")
        0

      {:error, reason} ->
        IO.puts("⚠️  Connection error for #{repo}: #{inspect(reason)}")
        0
    end
  end

  defp update_readme_with_stars(content, stars_map) do
    stars_map
    |> Enum.reduce(content, fn {repo, stars}, acc ->
      pattern = ~r/(\[([^\]]+)\]\(https:\/\/github\.com\/#{@owner}\/#{Regex.escape(repo)}\))( ⭐ \d+)?/

      replacement = "\\1 ⭐ #{stars}"

      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp sort_projects_in_sections(content, stars_map) do
    # Find all sections (## heading)
    sections = Regex.split(~r/(?=^## )/m, content)

    sections
    |> Enum.map(fn section ->
      if String.starts_with?(section, "## ") and not String.contains?(section, "🏆 Top 8 Projects") do
        sort_projects_in_section(section, stars_map)
      else
        section
      end
    end)
    |> Enum.join("")
  end

  defp sort_projects_in_section(section, _stars_map) do
    # Split section into header and content
    [header | rest] = String.split(section, "\n", parts: 2)
    content = Enum.join(rest, "\n")

    # Extract all project lines
    lines = String.split(content, "\n")

    {project_lines, other_lines} =
      lines
      |> Enum.split_with(fn line ->
        String.starts_with?(String.trim(line), "- [") and
        String.contains?(line, "github.com/#{@owner}/")
      end)

    # Sort project lines by stars
    sorted_projects =
      project_lines
      |> Enum.map(fn line ->
        # Extract repo name and stars count
        case Regex.run(~r/github\.com\/#{@owner}\/([^\)]+)\).*⭐ (\d+)/, line) do
          [_, _repo, stars_str] ->
            stars = String.to_integer(stars_str)
            {line, stars}
          _ ->
            {line, 0}
        end
      end)
      |> Enum.sort_by(fn {_line, stars} -> -stars end)
      |> Enum.map(fn {line, _stars} -> line end)

    # Reconstruct section
    header <> "\n" <> Enum.join(sorted_projects ++ other_lines, "\n")
  end

  defp update_top_projects_section(content, stars_map) do
    # Find project names and descriptions from original content
    repo_names = extract_repo_names(content)
    repo_descriptions = extract_repo_descriptions(content)

    # Sort projects by stars count (top 8)
    top_projects =
      stars_map
      |> Enum.sort_by(fn {_repo, stars} -> -stars end)
      |> Enum.take(8)
      |> Enum.map(fn {repo, stars} ->
        name = Map.get(repo_names, repo, repo)
        description = Map.get(repo_descriptions, repo, "")

        if description != "" do
          "- [#{name}](https://github.com/#{@owner}/#{repo}) – #{description} ⭐ #{stars}"
        else
          "- [#{name}](https://github.com/#{@owner}/#{repo}) ⭐ #{stars}"
        end
      end)
      |> Enum.join("\n")

    top_section = """
    ## 🏆 Top 8 Projects

    #{top_projects}

    """

    # Check if section already exists
    case Regex.run(~r/## 🏆 Top 8 Projects.*?(?=\n## |\z)/s, content) do
      nil ->
        # Add section before first section (before first ##)
        Regex.replace(
          ~r/(.*?\n\n)(## )/s,
          content,
          "\\1#{top_section}\n\\2",
          global: false
        )

      _existing ->
        # Update existing section
        Regex.replace(
          ~r/## 🏆 Top 8 Projects.*?(?=\n## |\z)/s,
          content,
          String.trim_trailing(top_section),
          global: false
        )
    end
  end

  defp extract_repo_names(content) do
    ~r/\[([^\]]+)\]\(https:\/\/github\.com\/#{@owner}\/([^\)]+)\)/
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [name, repo] -> {repo, name} end)
    |> Map.new()
  end

  defp extract_repo_descriptions(content) do
    # Extract project lines with descriptions
    ~r/- \[([^\]]+)\]\(https:\/\/github\.com\/#{@owner}\/([^\)]+)\).*? – ([^\n]+)/
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [_name, repo, description] ->
      {repo, String.trim(description)}
    end)
    |> Map.new()
  end
end

GithubStarsUpdater.run()
