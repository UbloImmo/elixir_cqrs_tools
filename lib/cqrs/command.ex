defmodule Cqrs.Command do
  alias Cqrs.{Command, CommandError, Documentation, DomainEvent, Guards, Metadata, Options, Input, Utils}

  @moduledoc """
  The `Command` macro allows you to define a command that encapsulates a struct definition,
  data validation, dependency validation, and dispatching of the command.

  ## Options

  * `require_all_fields` (:boolean) - If `true`, all fields will be required. Defaults to `true`
  * `dispatcher` (:atom) - A module that defines a `dispatch/2`.
  * `default_event_values` (:boolean) - If `true`, events created using `derive_event/1` or `derive_event/2`, will inherit default values from their command fields. Defaults to `true`.

  ## Examples

      defmodule CreateUser do
        use Cqrs.Command

        field :email, :string
        field :name, :string

        internal_field :id, :binary_id

        @impl true
        def handle_validate(command, _opts) do
          Ecto.Changeset.validate_format(command, :email, ~r/@/)
        end

        @impl true
        def after_validate(%{email: email} = command) do
          Map.put(command, :id, UUID.uuid5(:oid, email))
        end

        @impl true
        def handle_dispatch(_command, _opts) do
          {:ok, :dispatched}
        end
      end

  ### Creation

      iex> {:error, errors} = CreateUser.new()
      ...> errors
      %{email: [\"can't be blank\"], name: [\"can't be blank\"]}

      iex> {:ok, %CreateUser{email: email, name: name, id: id}} = CreateUser.new(email: "chris@example.com", name: "chris")
      ...> %{email: email, name: name, id: id}
      %{email: \"chris@example.com\", id: \"052c1984-74c9-522f-858f-f04f1d4cc786\", name: \"chris\"}

      iex> %CreateUser{id: "052c1984-74c9-522f-858f-f04f1d4cc786"} = CreateUser.new!(email: "chris@example.com", name: "chris")


  ### Dispatching

      iex> {:error, {:invalid_command, errors}} =
      ...> CreateUser.new(name: "chris", email: "wrong")
      ...> |> CreateUser.dispatch()
      ...> errors
      %{email: ["has invalid format"]}

      iex> CreateUser.new(name: "chris", email: "chris@example.com")
      ...> |> CreateUser.dispatch()
      {:ok, :dispatched}

  ## Event derivation

  You can derive [events](`Cqrs.DomainEvent`) directly from a command.

  see `derive_event/2`

      defmodule DeactivateUser do
        use Cqrs.Command

        field :id, :binary_id

        derive_event UserDeactivated
      end

  ## Usage with `Commanded`

      defmodule Commanded.Application do
        use Commanded.Application,
          otp_app: :my_app,
          default_dispatch_opts: [
            consistency: :strong,
            returning: :execution_result
          ],
          event_store: [
            adapter: Commanded.EventStore.Adapters.EventStore,
            event_store: MyApp.EventStore
          ]
      end

      defmodule DeactivateUser do
        use Cqrs.Command, dispatcher: Commanded.Application

        field :id, :binary_id

        derive_event UserDeactivated
      end

      iex> {:ok, event} = DeactivateUser.new(id: "052c1984-74c9-522f-858f-f04f1d4cc786")
      ...> |> DeactivateUser.dispatch()
      ...>  %{id: event.id, version: event.version}
      %{id: "052c1984-74c9-522f-858f-f04f1d4cc786", version: 1}

  """
  @type command :: struct()

  @doc """
  Allows one to define any custom data validation aside from casting and requiring fields.

  This callback is optional.

  Invoked when the `new()` or `new!()` function is called.
  """
  @callback handle_validate(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()

  @doc """
  Allows one to modify the incoming attrs before they are validated. Note that all attribute keys a converted to strings before this callback is invoked.

  This callback is optional.

  Invoked before the `handle_validate/2` callback is called.
  """
  @callback before_validate(map()) :: map()

  @doc """
  Allows one to modify the fully validated command. The changes to the command are validated again after this callback.

  This callback is optional.

  Invoked after the `handle_validate/2` callback is called.
  """
  @callback after_validate(command()) :: command()

  @doc """
  Called after `new` has completed.

  This callback is optional.
  """
  @callback after_create(command(), keyword()) :: {:ok, command()}

  @doc """
  This callback is intended to be used as a last chance to do any validation that performs IO.

  This callback is optional.

  Invoked before `handle_dispatch/2`.
  """
  @callback before_dispatch(command(), keyword()) :: {:ok, command()} | {:error, any()}

  @doc """
  This callback is intended to authorize the execution of the command.

  This callback is optional.

  Invoked after `before_dispatch/2` and before `handle_dispatch/2`.
  """
  @callback handle_authorize(command(), keyword()) :: {:ok, command()} | {:ok, :halt} | any()

  @doc """
  This callback is intended to be used to run the fully validated command.

  This callback is required.
  """
  @callback handle_dispatch(command(), keyword()) :: any()

  defmacro __using__(opts \\ []) do
    require_all_fields = Keyword.get(opts, :require_all_fields, true)
    create_jason_encoders = Application.get_env(:cqrs_tools, :create_jason_encoders, true)
    default_event_values = Keyword.get(opts, :default_event_values, true)

    quote location: :keep do
      Module.put_attribute(__MODULE__, :require_all_fields, unquote(require_all_fields))
      Module.put_attribute(__MODULE__, :default_event_values, unquote(default_event_values))
      Module.put_attribute(__MODULE__, :dispatcher, Keyword.get(unquote(opts), :dispatcher))
      Module.put_attribute(__MODULE__, :create_jason_encoders, unquote(create_jason_encoders))

      Module.register_attribute(__MODULE__, :events, accumulate: true)
      Module.register_attribute(__MODULE__, :options, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :schema_value_objects, accumulate: true)
      Module.register_attribute(__MODULE__, :required_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :simple_moduledoc, accumulate: false)

      require Cqrs.Options

      import Command,
        only: [field: 2, field: 3, derive_event: 1, derive_event: 2, internal_field: 2, internal_field: 3, option: 3]

      @options Cqrs.Options.tag_option()

      @desc nil
      @behaviour Command
      @before_compile Command
      @after_compile Command

      @impl true
      def before_validate(map), do: map

      @impl true
      def handle_validate(command, _opts), do: command

      @impl true
      def after_validate(command), do: command

      @impl true
      def after_create(command, _opts), do: {:ok, command}

      @impl true
      def before_dispatch(command, _opts), do: {:ok, command}

      @impl true
      def handle_authorize(command, _opts), do: {:ok, command}

      defoverridable handle_validate: 2,
                     before_dispatch: 2,
                     after_validate: 1,
                     before_validate: 1,
                     handle_authorize: 2,
                     after_create: 2
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep do
      Command.__module_docs__()
      Command.__schema__()
      Command.__introspection__()
      Command.__constructor__()
      Command.__changeset__()
      Command.__dispatch__()
      Command.__create_events__(__ENV__, @events, @schema_fields, @default_event_values)

      Module.delete_attribute(__MODULE__, :events)
      Module.delete_attribute(__MODULE__, :options)
      Module.delete_attribute(__MODULE__, :field_docs)
      Module.delete_attribute(__MODULE__, :option_docs)
      Module.delete_attribute(__MODULE__, :schema_fields)
      Module.delete_attribute(__MODULE__, :required_fields)
      Module.delete_attribute(__MODULE__, :simple_moduledoc)
      Module.delete_attribute(__MODULE__, :require_all_fields)
      Module.delete_attribute(__MODULE__, :default_event_values)
      Module.delete_attribute(__MODULE__, :schema_value_objects)
      Module.delete_attribute(__MODULE__, :create_jason_encoders)
    end
  end

  defmacro __after_compile__(_env, _bytecode) do
    quote location: :keep do
      if @dispatcher, do: Guards.ensure_is_dispatcher!(@dispatcher)
    end
  end

  defmacro __schema__ do
    quote generated: true, location: :keep do
      use Ecto.Schema

      if @create_jason_encoders and Code.ensure_loaded?(Jason), do: @derive(Jason.Encoder)

      @primary_key false
      embedded_schema do
        Ecto.Schema.field(:created_at, :utc_datetime)
        Ecto.Schema.field(:discarded_fields, :map, virtual: true)

        Enum.map(@schema_fields, fn
          {name, {:array, :enum}, opts} ->
          opts = opts |> Utils.sanitize_valid_ecto_opts()
            Ecto.Schema.field(name, {:array, Ecto.Enum}, opts)

          {name, :enum, opts} ->
          opts = opts |> Utils.sanitize_valid_ecto_opts()
            Ecto.Schema.field(name, Ecto.Enum, opts)

          {name, :binary_id, opts} ->
          opts = opts |> Utils.sanitize_valid_ecto_opts()
            Ecto.Schema.field(name, Ecto.UUID, opts)

          {name, type, opts} ->
          opts = opts |> Utils.sanitize_valid_ecto_opts()
            Ecto.Schema.field(name, type, opts)
        end)

        Enum.map(@schema_value_objects, fn
          {name, {:array, type}, _opts} ->
            Ecto.Schema.embeds_many(name, type)

          {name, type, _opts} ->
            Ecto.Schema.embeds_one(name, type)
        end)
      end
    end
  end

  defmacro __introspection__ do
    quote do
      @name __MODULE__ |> Module.split() |> Enum.reverse() |> hd() |> to_string()

      def __fields__, do: @schema_fields ++ @schema_value_objects

      def __field_names__(:public) do
        Enum.filter(__fields__(), fn {_, _, opts} ->
          Keyword.get(opts, :internal, false) == false
        end)
        |> Enum.map(&elem(&1, 0))
      end

      def __field_names__(:internal) do
        Enum.filter(__fields__(), fn {_, _, opts} ->
          Keyword.get(opts, :internal, false) == true
        end)
        |> Enum.map(&elem(&1, 0))
      end

      def __field_names__(:required), do: Enum.map(@required_fields, &elem(&1, 0))

      def __simple_moduledoc__, do: @simple_moduledoc
      def __required_fields__, do: @required_fields
      def __module_docs__, do: @moduledoc
      def __command__, do: __MODULE__
      def __name__, do: @name
    end
  end

  defmacro __module_docs__ do
    quote do
      require Documentation

      case Module.get_attribute(__MODULE__, :moduledoc) do
        {_, doc} -> @simple_moduledoc String.trim(doc)
        _ -> @simple_moduledoc nil
      end

      moduledoc = @moduledoc || ""
      @field_docs Documentation.field_docs("Fields", @schema_fields, @required_fields)
      @option_docs Documentation.option_docs(@options)

      Module.put_attribute(
        __MODULE__,
        :moduledoc,
        {1, moduledoc <> @field_docs <> "\n" <> @option_docs}
      )
    end
  end

  defmacro __constructor__ do
    quote generated: true, location: :keep do
      @default_opts Cqrs.Options.defaults()

      defp get_opts(opts) do
        Keyword.merge(@default_opts, Cqrs.Options.normalize(opts))
      end

      # @spec new(maybe_improper_list() | map(), maybe_improper_list()) :: struct()
      # @spec new!(maybe_improper_list() | map(), maybe_improper_list()) :: %__MODULE__{}

      @doc """
      Creates a new `#{__MODULE__} command.`

      #{@moduledoc}
      """
      def new(attrs \\ [], opts \\ []) when is_list(opts),
        do: Command.__new__(__MODULE__, attrs, @required_fields, get_opts(opts))

      @doc """
      Creates a new `#{__MODULE__} command.`

      #{@moduledoc}
      """
      def new!(attrs \\ [], opts \\ []) when is_list(opts),
        do: Command.__new__!(__MODULE__, attrs, @required_fields, get_opts(opts))
    end
  end

  defmacro __changeset__ do
    quote generated: true, location: :keep do
      def changeset(attrs, opts \\ []) when is_map(attrs) or is_list(attrs) do
        alias Ecto.Changeset, as: CS

        attrs =
          attrs
          |> Input.normalize_input(__MODULE__)
          |> __MODULE__.before_validate()
          |> Input.normalize_input(__MODULE__)

        fields = Enum.map(@schema_fields, &elem(&1, 0))
        associations = Enum.map(@schema_value_objects, &elem(&1, 0))

        changeset =
          %__MODULE__{}
          |> CS.cast(attrs, fields)
          |> __MODULE__.handle_validate(opts)

        associations
        |> Enum.reduce(changeset, &CS.cast_assoc(&2, &1))
        |> CS.validate_required(@required_fields)
      end
    end
  end

  defmacro __dispatch__ do
    quote location: :keep do
      def dispatch(command, opts \\ [])

      def dispatch(%__MODULE__{} = command, opts) do
        Command.__do_dispatch__(__MODULE__, command, get_opts(opts))
      end

      def dispatch({:ok, %__MODULE__{} = command}, opts) do
        Command.__do_dispatch__(__MODULE__, command, get_opts(opts))
      end

      def dispatch({:error, errors}, _opts) do
        {:error, {:invalid_command, errors}}
      end

      if @dispatcher do
        @impl true
        def handle_dispatch(%__MODULE__{} = cmd, opts) do
          @dispatcher.dispatch(cmd, opts)
        end
      end
    end
  end

  def __create_events__(env, events, fields, default_event_values) do
    command_fields =
      Enum.map(fields, fn {name, _type, opts} ->
        case default_event_values do
          true -> {name, Keyword.get(opts, :default)}
          false -> name
        end
      end)
      |> Macro.escape()

    create_event = fn {name, opts, {file, line}} ->
      options =
        opts
        |> Keyword.update(:with, command_fields, fn fields ->
          fields
          |> List.wrap()
          |> Kernel.++(command_fields)
          |> Enum.uniq()
        end)
        |> Keyword.update(:drop, [:discarded_fields], fn drops ->
          Enum.uniq([:discarded_fields | List.wrap(drops)])
        end)

      domain_event =
        quote do
          use DomainEvent, unquote(options)
        end

      env =
        env
        |> Map.put(:file, file)
        |> Map.put(:line, line)

      Module.create(name, domain_event, env)
    end

    Enum.map(events, create_event)
  end

  @doc """
  Defines a command field.

  * `:name` - any `atom`
  * `:type` - any valid [Ecto Schema](`Ecto.Schema`) type
  * `:opts` - any valid [Ecto Schema](`Ecto.Schema`) field options. Plus:

      * `:required` - `true | false`. Defaults to the `require_all_fields` option.
      * `:internal` - `true | false`. If `true`, this field is meant to be used internally. If `true`, the required option will be set to `false` and the field will be hidden from documentation.
      * `:description` - Documentation for the field.
  """

  @spec field(name :: atom(), type :: atom(), keyword()) :: any()
  defmacro field(name, type, opts \\ []) do
    quote location: :keep do
      required =
        case Keyword.get(unquote(opts), :internal, false) do
          true ->
            false

          false ->
            required = Keyword.get(unquote(opts), :required, @require_all_fields)
            if required, do: @required_fields(unquote(name))
            required
        end

      opts =
        unquote(opts)
        |> Keyword.put(:required, required)
        |> Keyword.update(:description, @desc, &Function.identity/1)

      # reset the @desc attr
      @desc nil

      if Command.__is_value_object__?(unquote(type)) do
        @schema_value_objects {unquote(name), unquote(type), opts}
      else
        @schema_fields {unquote(name), unquote(type), opts}
      end
    end
  end

  def __is_value_object__?({:array, type}),
    do: Guards.exports_function?(type, :__value_object__, 0)

  def __is_value_object__?(type),
    do: Guards.exports_function?(type, :__value_object__, 0)

  @doc """
  The same as `field/3` but sets the option `internal` to `true`.

  This helps with readability of commands with a large number of fields.
  """
  @spec internal_field(name :: atom(), type :: atom(), keyword()) :: any()
  defmacro internal_field(name, type, opts \\ []) do
    quote do
      field(unquote(name), unquote(type), Keyword.put(unquote(opts), :internal, true))
    end
  end

  @doc """
  Describes a supported option for this command.

  ## Options
  * `:default` - this default value if the option is not provided.
  * `:description` - The documentation for this option.
  """

  @spec option(name :: atom(), hint :: atom(), keyword()) :: any()
  defmacro option(name, hint, opts) do
    quote do
      Options.option(unquote(name), unquote(hint), unquote(opts))
    end
  end

  @doc """
  Generates an [event](`Cqrs.DomainEvent`) based on the fields defined in the [command](`Cqrs.Command`).

  Accepts all the options that [DomainEvent](`Cqrs.DomainEvent`) accepts.
  """
  defmacro derive_event(name, opts \\ []) do
    quote do
      [_command_name | namespace] =
        __MODULE__
        |> Module.split()
        |> Enum.reverse()

      namespace =
        namespace
        |> Enum.reverse()
        |> Module.concat()

      name = Module.concat(namespace, unquote(name))
      @events {name, unquote(opts), {__ENV__.file, __ENV__.line}}
    end
  end

  alias Ecto.Changeset

  def __init__(mod, attrs, required_fields, opts) do
    fields = mod.__schema__(:fields)
    embeds = mod.__schema__(:embeds)

    changeset =
      mod
      |> struct()
      |> Changeset.cast(attrs, fields -- embeds)

    embeds
    |> Enum.reduce(changeset, &Changeset.cast_embed(&2, &1))
    |> Changeset.validate_required(required_fields)
    |> mod.handle_validate(opts)
  end

  def __new__(mod, attrs, required_fields, opts) when is_list(opts) do
    attrs =
      attrs
      |> Input.normalize_input(mod)
      |> mod.before_validate()
      |> Input.normalize_input(mod)

    opts = Metadata.put_default_metadata(opts)

    mod
    |> __init__(attrs, required_fields, opts)
    |> Changeset.put_change(:created_at, Cqrs.Clock.utc_now(mod))
    |> case do
      %{valid?: false} = changeset ->
        {:error, changeset}

      %{valid?: true} = changeset ->
        attrs =
          changeset
          |> Changeset.apply_changes()
          |> mod.after_validate()
          |> Input.normalize_input(mod)

        changeset2 = __init__(mod, attrs, required_fields, opts)

        changeset
        |> Changeset.merge(changeset2)
        |> Changeset.apply_action(:create)
    end
    |> case do
      {:ok, command} ->
        command
        |> Map.put(:discarded_fields, discarded_data(mod, attrs))
        |> mod.after_create(opts)

      {:error, changeset} ->
        {:error, format_errors(changeset)}
    end
  end

  def __new__!(mod, attrs, required_fields, opts \\ []) when is_list(opts) do
    case __new__(mod, attrs, required_fields, opts) do
      {:ok, command} -> command
      {:error, errors} -> raise CommandError, errors: errors
    end
  end

  defp discarded_data(mod, attrs) do
    fields = mod.__schema__(:fields) |> Enum.map(&to_string/1)
    Map.drop(attrs, fields)
  end

  defp format_errors(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  def __do_dispatch__(mod, %{__struct__: mod} = command, opts) do
    opts = Metadata.put_default_metadata(opts)

    case mod.before_dispatch(command, opts) do
      {:error, errors} when is_list(errors) -> {:error, List.flatten(errors)}
      {:error, error} -> {:error, error}
      {:ok, command} -> run_dispatch(mod, command, opts)
      %{__struct__: ^mod} = command -> run_dispatch(mod, command, opts)
    end
  end

  defp run_dispatch(mod, command, opts) do
    tag? = Keyword.get(opts, :tag?)

    case mod.handle_authorize(command, opts) do
      {:ok, :halt} ->
        tag_result({:ok, command}, tag?)

      {:ok, command} ->
        command
        |> mod.handle_dispatch(opts)
        |> tag_result(tag?)

      _ ->
        {:error, :unauthorized}
    end
  end

  defp tag_result({:ok, result}, true), do: {:ok, result}
  defp tag_result({:error, result}, true), do: {:error, result}
  defp tag_result(result, true), do: {:ok, result}
  defp tag_result(result, _), do: result
end
