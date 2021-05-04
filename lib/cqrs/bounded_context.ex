defmodule Cqrs.BoundedContext do
  alias Cqrs.BoundedContext

  defmodule InvalidCommandError do
    defexception [:command]
    def message(%{command: command}), do: "#{command} is not a Cqrs.Command"
  end

  defmodule InvalidQueryError do
    defexception [:query]
    def message(%{query: query}), do: "#{query} is not a Cqrs.Query"
  end

  @moduledoc """
  Macros to create proxy functions to [commands](`#{Command}`) and [queries](`#{Query}`) in a module.

  ## Examples
      defmodule Users do
        use Cqrs.BoundedContext

        command CreateUser
        command CreateUser, as: :create_user2

        query GetUser
        query GetUser, as: :get_user2
      end

  ### Commands

      iex> {:error, {:invalid_command, state}} =
      ...> Users.create_user(name: "chris", email: "wrong")
      ...> state.errors
      %{email: ["has invalid format"]}

      iex> {:error, {:invalid_command, state}} =
      ...> Users.create_user2(name: "chris", email: "wrong")
      ...> state.errors
      %{email: ["has invalid format"]}

      iex> Users.create_user(name: "chris", email: "chris@example.com")
      {:ok, :dispatched}

      iex> Users.create_user2(name: "chris", email: "chris@example.com")
      {:ok, :dispatched}

  ### Queries

      iex> Users.get_user!()
      ** (Cqrs.Query.QueryError) %{email: ["can't be blank"]}

      iex> Users.get_user2!()
      ** (Cqrs.Query.QueryError) %{email: ["can't be blank"]}

      iex> Users.get_user!(email: "wrong")
      ** (Cqrs.Query.QueryError) %{email: ["has invalid format"]}

      iex> {:error, %{errors: errors}} = Users.get_user()
      ...> errors
      [email: {"can't be blank", [validation: :required]}]

      iex> {:error, %{errors: errors}} = Users.get_user(email: "wrong")
      ...> errors
      [email: {"has invalid format", [validation: :format]}]

      iex> {:ok, query} = Users.get_user_query(email: "chris@example.com")
      ...> query
      #Ecto.Query<from u0 in User, where: u0.email == ^"chris@example.com">

      iex> {:ok, user} = Users.get_user(email: "chris@example.com")
      ...> %{id: user.id, email: user.email}
      %{id: "052c1984-74c9-522f-858f-f04f1d4cc786", email: "chris@example.com"}

  ### Usage with `#{Commanded}`

    If you are a Commanded user, you have already registered your commands with your commanded routers.
    Instead of repeating yourself, you can cut down on boilerplate with the `import_commands/1` macro.

    Since `Commanded` is an optional dependency, you need to explicitly import `Cqrs.BoundedContext` to
    bring the macro into scope.

      defmodule UsersEnhanced do
        use Cqrs.BoundedContext
        import Cqrs.BoundedContext

        import_commands CommandedRouter

        query GetUser
        query GetUser, as: :get_user2
      end
  """

  defmacro __using__(_) do
    quote do
      Module.register_attribute(__MODULE__, :queries, accumulate: true)
      Module.register_attribute(__MODULE__, :commands, accumulate: true)

      import BoundedContext, only: [command: 1, command: 2, query: 1, query: 2]

      @before_compile BoundedContext
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      commands = Enum.map(@commands, &BoundedContext.__command_proxy__/1)
      queries = Enum.map(@queries, &BoundedContext.__query_proxy__/1)

      Module.eval_quoted(__ENV__, commands)
      Module.eval_quoted(__ENV__, queries)

      Module.delete_attribute(__MODULE__, :queries)
      Module.delete_attribute(__MODULE__, :commands)
    end
  end

  defmacro command(command_module, opts \\ []) do
    quote location: :keep do
      _ = unquote(command_module).__info__(:functions)

      unless function_exported?(unquote(command_module), :__command__, 0) do
        raise InvalidCommandError, command: unquote(command_module)
      end

      function_name = BoundedContext.__function_name__(unquote(command_module), unquote(opts))
      @commands {unquote(command_module), function_name}
    end
  end

  def __command_proxy__({command_module, function_name}) do
    quote do
      def unquote(function_name)(attrs \\ [], opts \\ []) do
        BoundedContext.__dispatch_command__(unquote(command_module), attrs, opts)
      end

      def unquote(:"#{function_name}!")(attrs \\ [], opts \\ []) do
        BoundedContext.__dispatch_command__!(unquote(command_module), attrs, opts)
      end
    end
  end

  defmacro query(query_module, opts \\ []) do
    quote location: :keep do
      _ = unquote(query_module).__info__(:functions)

      unless function_exported?(unquote(query_module), :__query__, 0) do
        raise InvalidQueryError, query: unquote(query_module)
      end

      function_name = BoundedContext.__function_name__(unquote(query_module), unquote(opts))
      @queries {unquote(query_module), function_name}
    end
  end

  def __query_proxy__({query_module, function_name}) do
    quote do
      def unquote(function_name)(attrs \\ [], opts \\ []) do
        BoundedContext.__execute_query__(unquote(query_module), attrs, opts)
      end

      def unquote(:"#{function_name}!")(attrs \\ [], opts \\ []) do
        BoundedContext.__execute_query__!(unquote(query_module), attrs, opts)
      end

      def unquote(:"#{function_name}_query")(attrs \\ [], opts \\ []) do
        BoundedContext.__create_query__(unquote(query_module), attrs, opts)
      end

      def unquote(:"#{function_name}_query!")(attrs \\ [], opts \\ []) do
        BoundedContext.__create_query__!(unquote(query_module), attrs, opts)
      end
    end
  end

  def __function_name__(module, opts) do
    [name | _] =
      module
      |> Module.split()
      |> Enum.reverse()

    default_function_name =
      name
      |> to_string
      |> Macro.underscore()
      |> String.to_atom()

    Keyword.get(opts, :as, default_function_name)
  end

  def __dispatch_command__(module, attrs, opts) do
    then = Keyword.get(opts, :then, &Function.identity/1)

    attrs
    |> module.new(opts)
    |> module.dispatch(opts)
    |> __handle_command_result__(then)
  end

  def __dispatch_command__!(module, attrs, opts) do
    then = Keyword.get(opts, :then, &Function.identity/1)

    attrs
    |> module.new!(opts)
    |> module.dispatch(opts)
    |> __handle_command_result__(then)
  end

  def __handle_command_result__(result, fun) when is_function(fun, 1), do: fun.(result)

  def __handle_command_result__(_result, _other), do: raise("'then' should be a function/1")

  def __create_query__(module, attrs, opts) do
    module.new(attrs, opts)
  end

  def __create_query__!(module, attrs, opts) do
    module.new!(attrs, opts)
  end

  def __execute_query__(module, attrs, opts) do
    attrs
    |> module.new(opts)
    |> module.execute(opts)
  end

  def __execute_query__!(module, attrs, opts) do
    attrs
    |> module.new!(opts)
    |> module.execute(opts)
  end

  if Code.ensure_loaded?(Commanded) do
    @doc """
    Imports all of a [Command Router's](`#{Commanded.Commands.Router}`) registered commands.
    """
    defmacro import_commands(router) do
      quote do
        _ = unquote(router).__info__(:functions)

        unless function_exported?(unquote(router), :__registered_commands__, 0) do
          raise "#{unquote(router)} is required to be a .#{Commanded.Commands.Router}"
        end

        unquote(router).__registered_commands__()
        |> Macro.escape()
        |> Enum.map(&BoundedContext.command/1)
      end
    end
  end
end
