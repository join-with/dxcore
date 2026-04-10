defmodule DxCore.Agents.CLI.CommandTemplate do
  @moduledoc """
  Interpolates task metadata placeholders into a command template string.

  Used by the agent CLI when `--command-template` is set, to override
  commands from the coordinator payload.
  """

  @known_placeholders ~w(package task hash shard_index shard_count command)

  @spec interpolate(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def interpolate(template, params) do
    with :ok <- validate_placeholders(template),
         {:ok, result} <- replace_placeholders(template, params) do
      case String.trim(result) do
        "" -> {:error, "Template produced empty command"}
        cmd -> {:ok, cmd}
      end
    end
  end

  defp validate_placeholders(template) do
    case Regex.scan(~r/\{(\w+)\}/, template) do
      [] ->
        :ok

      matches ->
        unknown =
          matches
          |> Enum.map(fn [_, name] -> name end)
          |> Enum.reject(&(&1 in @known_placeholders))

        case unknown do
          [] -> :ok
          [first | _] -> {:error, "Unknown placeholder: {#{first}}"}
        end
    end
  end

  defp replace_placeholders(template, params) do
    placeholders_used =
      Regex.scan(~r/\{(\w+)\}/, template)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()

    case find_empty_placeholder(placeholders_used, params) do
      nil ->
        result =
          Enum.reduce(placeholders_used, template, fn name, acc ->
            String.replace(acc, "{#{name}}", params[name] || "")
          end)

        {:ok, result}

      name ->
        {:error, "Placeholder {#{name}} resolved to empty value"}
    end
  end

  defp find_empty_placeholder(names, params) do
    Enum.find(names, fn name ->
      value = params[name]
      is_nil(value) or value == ""
    end)
  end
end
