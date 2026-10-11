defmodule Jantar.Sysfs do
  @moduledoc """
  Reading /proc, /sys, /run and /etc under a configurable root, so the same
  sensor code reads the live machine (root "/") or a fixture tree in tests.

  Paths are written as on the real system ("/proc/stat") and joined onto the
  root. Every read is quiet: a missing or unreadable file is `nil`, the way
  hud's `rd()` returns None.
  """

  @doc "The real path for `path` under `root`."
  def path(root, path), do: Path.join(root, path)

  @doc "A file's contents, trimmed; nil if it can't be read."
  def read(root, path) do
    case File.read(path(root, path)) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end

  @doc "A file's raw contents (e.g. NUL-separated /proc/<pid>/cmdline); nil if unreadable."
  def read_raw(root, path) do
    case File.read(path(root, path)) do
      {:ok, bytes} -> bytes
      {:error, _} -> nil
    end
  end

  @doc "A numeric file (\"42\", \"5180.0\") as a float; nil if missing or not a number."
  def number(root, path), do: Jantar.Core.number(read(root, path))

  @doc "Whether the path exists (file, directory or symlink target)."
  def exists?(root, path), do: File.exists?(path(root, path))

  @doc "Whether the path is a directory."
  def dir?(root, path), do: File.dir?(path(root, path))

  @doc """
  Paths matching a glob, sorted, and given back as system paths (without the
  root) so they can be passed to `read/2` again.
  """
  def wildcard(root, pattern) do
    prefix = String.trim_trailing(root, "/")

    path(root, pattern)
    |> Path.wildcard()
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.sort()
  end

  @doc """
  The canonical system path with every symlink resolved, like realpath(3)
  (Erlang has none built in). sysfs is full of relative links, often through
  directories that are links themselves (/sys/class/drm/card0 is one), so each
  component is resolved in turn. Links are read under `root`.
  """
  def realpath(root, path), do: walk(root, Path.split(path), "/", 0)

  # Give up on link loops, as the kernel does after 40 links.
  defp walk(_root, parts, acc, 40), do: Path.join([acc | parts])
  defp walk(_root, [], acc, _links), do: acc
  defp walk(root, ["/" | rest], _acc, links), do: walk(root, rest, "/", links)
  defp walk(root, ["." | rest], acc, links), do: walk(root, rest, acc, links)
  defp walk(root, [".." | rest], acc, links), do: walk(root, rest, Path.dirname(acc), links)

  defp walk(root, [part | rest], acc, links) do
    candidate = Path.join(acc, part)

    case File.read_link(path(root, candidate)) do
      # A link: continue from its target, relative to the directory it's in.
      {:ok, target} -> walk(root, Path.split(target) ++ rest, acc, links + 1)
      {:error, _} -> walk(root, rest, candidate, links)
    end
  end
end
