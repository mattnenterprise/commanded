defmodule Commanded.Application do
  @moduledoc """
  Defines a Commanded application.

  The application expects at least an `:otp_app` option to be specified. It
  should point to an OTP application that has the application configuration.

  For example, the application:

      defmodule MyApp.Application do
        use Commanded.Application, otp_app: :my_app

        router(MyApp.Router)
      end

  Could be configured with:

      # config/config.exs
      config :my_app, MyApp.Application
        event_store: [
          adapter: Commanded.EventStore.Adapters.EventStore,
          event_store: MyApp.EventStore
        ],
        pubsub: :local,
        registry: :local

  Alternatively, you can include the configuration when defining the
  application:

      defmodule MyApp.Application do
        use Commanded.Application,
          otp_app: :my_app,
          event_store: [
            adapter: Commanded.EventStore.Adapters.EventStore,
            event_store: MyApp.EventStore
          ],
          pubsub: :local,
          registry: :local

        router(MyApp.Router)
      end

  A Commanded application must be started before it can be used:

      {:ok, _pid} = MyApp.Application.start_link()

  Instead of starting the application manually, you should use a
  [Supervisor](supervision.html).

  ## Supervision

  Use a supervisor to start your Commanded application:

      Supervisor.start_link([
        MyApp.Application
      ], strategy: :one_for_one)

  ## Command routing

  Commanded applications are also composite routers allowing you to include
  one or more routers within an application.

  ### Example

      defmodule MyApp.Application do
        use Commanded.Application, otp_app: :my_app

        router(MyApp.Accounts.Router)
        router(MyApp.Billing.Router)
        router(MyApp.Notifications.Router)
      end

  See `Commanded.Commands.CompositeRouter` for details.

  ## Dynamic named applications

  An application can be provided with a name as an option to `start_link/1`.
  This can be used to start the same application multiple times, each using its
  own separately configured and isolated event store. Each application must be
  started with a unique name.

  Multipe instances of the same event handler or process manager can be
  started by refering to a started application by its name. The event store
  operations can also be scoped to an application by referring to its name.

  ### Example

  Start an application process for each tenant in a multi-tenanted app,
  guaranteeing that the data and processing remains isolated between tenants.

      for tenant <- [:tenant1, :tenant2, :tenant3] do
        {:ok, _app} = MyApp.Application.start_link(name: tenant)
      end

  Typically you would start the applications using a supervisor:

      children =
        for tenant <- [:tenant1, :tenant2, :tenant3] do
          {MyApp.Application, name: tenant}
        end

      Supervisor.start_link(children, strategy: :one_for_one)

  To dispatch a command you must provide the application name:

      :ok = MyApp.Application.dispatch(command, application: :tenant1)


  ## Default dispatch options

  An application can be configured with default command dispatch options such as
  `:consistency`, `:timeout`, and `:returning`. Any defaults will be used
  unless overridden by options provided to the dispatch function.

      defmodule MyApp.Application do
        use Commanded.Application,
          otp_app: :my_app,
          default_dispatch_opts: [
            consistency: :eventual,
            returning: :aggregate_version
          ]
      end

  See the `Commanded.Commands.Router` module for more details about the
  supported options.
  """

  @type t :: module

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Commanded.Application

      {otp_app, config} = Commanded.Application.Supervisor.compile_config(__MODULE__, opts)

      @otp_app otp_app
      @config config

      use Commanded.Commands.CompositeRouter,
        application: __MODULE__,
        default_dispatch_opts: Keyword.get(opts, :default_dispatch_opts, [])

      def config do
        {:ok, config} =
          Commanded.Application.Supervisor.runtime_config(__MODULE__, @otp_app, @config, [])

        config
      end

      def child_spec(opts) do
        %{
          id: name(opts),
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(opts \\ []) do
        name = name(opts)

        Commanded.Application.Supervisor.start_link(__MODULE__, @otp_app, @config, name, opts)
      end

      def stop(pid, timeout \\ 5000) do
        Supervisor.stop(pid, :normal, timeout)
      end

      defp name(opts) do
        case Keyword.get(opts, :name) do
          nil ->
            __MODULE__

          name when is_atom(name) ->
            name

          invalid ->
            raise ArgumentError,
              message:
                "expected :name option to be an atom but got: " <>
                  inspect(invalid)
        end
      end
    end
  end

  ## User callbacks

  @optional_callbacks init: 1

  @doc """
  A callback executed when the application starts.

  It must return `{:ok, keyword}` with the updated list of configuration.
  """
  @callback init(config :: Keyword.t()) :: {:ok, Keyword.t()}

  @doc """
  Returns the application configuration stored in the `:otp_app` environment.
  """
  @callback config() :: Keyword.t()

  @doc """
  Starts the application supervisor.

  Returns `{:ok, pid}` on sucess, `{:error, {:already_started, pid}}` if the
  application is already started, or `{:error, term}` in case anything else goes
  wrong.
  """
  @callback start_link(opts :: Keyword.t()) ::
              {:ok, pid}
              | {:error, {:already_started, pid}}
              | {:error, term}

  @doc """
  Shuts down the application.
  """
  @callback stop(pid, timeout) :: :ok

  @doc """
  Dispatch a registered command.

    - `command` is a command struct which must be registered with a
      `Commanded.Commands.Router` and included in the application.
      
    - `timeout_or_opts` is either an integer timeout or a keyword list of
      options. The timeout must be an integer greater than zero which
      specifies how many milliseconds to allow the command to be handled, or
      the atom `:infinity` to wait indefinitely. The default timeout value is
      five seconds.

      Alternatively, an options keyword list can be provided, it supports the
      following options.

      Options:

        - `causation_id` - an optional UUID used to identify the cause of the
          command being dispatched.

        - `correlation_id` - an optional UUID used to correlate related
          commands/events together.

        - `consistency` - one of `:eventual` (default) or `:strong`. By
          setting the consistency to `:strong` a successful command dispatch
          will block until all strongly consistent event handlers and process
          managers have handled all events created by the command.

        - `metadata` - an optional map containing key/value pairs comprising
          the metadata to be associated with all events created by the
          command.

        - `returning` - to choose what response is returned from a successful
            command dispatch. The default is to return an `:ok`.

            The available options are:

            - `:aggregate_state` - to return the update aggregate state in the
              successful response: `{:ok, aggregate_state}`.

            - `:aggregate_version` - to include the aggregate stream version
              in the successful response: `{:ok, aggregate_version}`.

            - `:execution_result` - to return a `Commanded.Commands.ExecutionResult`
              struct containing the aggregate's identity, version, and any
              events produced from the command along with their associated
              metadata.

            - `false` - don't return anything except an `:ok`.

        - `timeout` - as described above.

  Returns `:ok` on success unless the `:returning` option is specified where
  it returns one of `{:ok, aggregate_state}`, `{:ok, aggregate_version}`, or
  `{:ok, %Commanded.Commands.ExecutionResult{}}`.

  Returns `{:error, reason}` on failure.

  ## Example

      command = %OpenAccount{account_number: "ACC123", initial_balance: 1_000}

      :ok = BankApp.dispatch(command, timeout: 30_000)

  """
  @callback dispatch(command :: struct, timeout_or_opts :: integer | :infinity | Keyword.t()) ::
              :ok
              | {:ok, aggregate_state :: struct}
              | {:ok, aggregate_version :: non_neg_integer()}
              | {:ok, execution_result :: Commanded.Commands.ExecutionResult.t()}
              | {:error, :unregistered_command}
              | {:error, :consistency_timeout}
              | {:error, reason :: term}

  alias Commanded.Application.Config

  @doc false
  def dispatch(application, command, opts \\ [])

  def dispatch(application, command, timeout) when is_integer(timeout),
    do: dispatch(application, command, timeout: timeout)

  def dispatch(application, command, :infinity),
    do: dispatch(application, command, timeout: :infinity)

  def dispatch(application, command, opts) do
    opts = Keyword.put(opts, :application, application)

    application_module(application).dispatch(command, opts)
  end

  @doc false
  def application_module(application), do: Config.get(application, :application)

  @doc false
  @spec event_store_adapter(Commanded.Application.t()) :: {module, map}
  def event_store_adapter(application), do: Config.get(application, :event_store)

  @doc false
  @spec pubsub_adapter(Commanded.Application.t()) :: {module, map}
  def pubsub_adapter(application), do: Config.get(application, :pubsub)

  @doc false
  @spec registry_adapter(Commanded.Application.t()) :: {module, map}
  def registry_adapter(application), do: Config.get(application, :registry)
end
