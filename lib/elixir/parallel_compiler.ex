defmodule Elixir.ParallelCompiler do
  refer Erlang.orddict, as: Orddict

  defexception Error, modules: [] do
    def message(exception) do
      "compilation failed: the following modules were not found " <>
        "or there is a cyclic dependency between them: #{inspect exception.modules}"
    end
  end

  defmacrop default_callback, do: quote(do: fn(x, _) -> x end)

  @doc """
  Compiles the given files.

  Those files are compiled in parallel and can automatically
  detect dependencies between them. Once a dependency is found,
  the current file stops being compiled until the dependency is
  resolved.

  A callback that receives every time a file is compiled
  with the module names and binaries defined inside it can
  be optionally given as argument.
  """
  def files(files, callback // default_callback) do
    files_to_path(files, nil, callback)
  end

  @doc """
  Compiles the given files to the given path.
  Read files/2 for more information.
  """
  def files_to_path(files, path, callback // default_callback) do
    Code.ensure_loaded(Elixir.ErrorHandler)
    files = Enum.map(files, to_char_list(&1))
    path  = if path, do: to_char_list(path)
    spawn_compilers(files, path, callback, [], [], [])
  end

  # We already have 4 currently running, don't spawn new ones
  defp spawn_compilers(files, output, callback, waiting, queued, result) when
      length(queued) - length(waiting) >= 4 do
    wait_for_messages(files, output, callback, waiting, queued, result)
  end

  # Spawn a compiler for each file in the list until we reach the limit
  defp spawn_compilers([h|t], output, callback, waiting, queued, result) do
    parent = Process.self()
    child  = spawn_link fn ->
      Process.put(:elixir_parent_compiler, parent)
      Process.flag(:error_handler, Elixir.ErrorHandler)
      result = if output do
        Erlang.elixir_compiler.file_to_path(h, output)
      else:
        Erlang.elixir_compiler.file(h)
      end
      parent <- { :compiled, Process.self(), h, result }
    end
    spawn_compilers(t, output, callback, waiting, [child|queued], result)
  end

  # No more files, nothing waiting, queue is empty, we are done
  defp spawn_compilers([], _output, _callback, [], [], result), do: result

  # Queued x, waiting for x: ERROR!
  defp spawn_compilers([], _output, _callback, waiting, queued, _result) when length(waiting) == length(queued) do
    raise Error, modules: Enum.map(waiting, elem(&1, 2))
  end

  # No more files, but queue and waiting are not full or do not match
  defp spawn_compilers([], output, callback, waiting, queued, result) do
    wait_for_messages([], output, callback, waiting, queued, result)
  end

  # Wait for messages from child processes
  defp wait_for_messages(files, output, callback, waiting, queued, result) do
    receive do
    match: { :compiled, child, file, new }
      callback.(list_to_binary(file), new)

      new_waiting = List.foldl(new, waiting, release_waiting_processes(&1, &2))
      new_queued  = List.delete(queued, child)
      new_result  = result ++ new

      spawn_compilers(files, output, callback, new_waiting, new_queued, new_result)
    match: { :waiting, child, on }
      new_waiting = Orddict.store(child, on, waiting)
      spawn_compilers(files, output, callback, new_waiting, queued, result)
    match: { :EXIT, _child, :normal }
      wait_for_messages(files, output, callback, waiting, queued, result)
    match: { :EXIT, _child, { reason, where } }
      Erlang.erlang.raise(:error, reason, where)
    match: { :EXIT, _child, other } when other
      Erlang.erlang.error(other)
    end
  end

  # Release waiting processes that are waiting for the given module
  defp release_waiting_processes({ module, _binary }, waiting) do
    Enum.filter waiting, fn({ child, waiting_module }) ->
      if waiting_module == module do
        child <- { :release, Process.self() }
        false
      else:
        true
      end
    end
  end
end