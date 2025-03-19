defmodule Cqrs.Utils do

  @ecto_valid_options [
    # field/3 valid options
    :default,
    :source,
    :autogenerate,
    :read_after_writes,
    :virtual,
    :primary_key,
    :load_in_query,
    :redact,
    :foreign_key,
    :on_replace,
    :defaults,
    :type,
    :where,
    :references,
    :skip_default_validation,
    :writable,
    :values,
    # valid has_options (has_one, has_many
    :through,
    :on_delete,
    :preload_order,
    # valid belongs_to options
    :define_field
  ]

  @doc """
  Filters a keyword list of options to only include valid Ecto schema field options.

  Takes a keyword list of options and returns a new keyword list containing only the keys that
  are recognized by Ecto for schema field definitions.

  ## Examples

      iex> options = [default: "value", virtual: true, custom_option: "something"]
      iex> Cqrs.Utils.sanitize_valid_ecto_opts(options)
      [default: "value", virtual: true]

  For more details, see [Ecto.Schema](https://hexdocs.pm/ecto/Ecto.Schema.html#field/3).
  """
  def sanitize_valid_ecto_opts(opts) do
    opts |> Keyword.take(@ecto_valid_options)
  end

end
