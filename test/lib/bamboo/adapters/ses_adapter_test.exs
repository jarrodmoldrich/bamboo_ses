defmodule Bamboo.SesAdapterTest do
  use ExUnit.Case
  import Mox
  alias Bamboo.{Email, Mailer, SesAdapter}
  alias BambooSes.EmailParser
  alias ExAws.Request.HttpMock
  require IEx

  defp new_email(to \\ "alice@example.com", subject \\ "Welcome to the app.") do
    Email.new_email(
      to: to,
      from: "bob@example.com",
      cc: "john@example.com",
      bcc: "jane@example.com",
      subject: subject,
      headers: %{"Reply-To" => "chuck@example.com"},
      html_body: "<strong>Thanks for joining!</strong>",
      text_body: "Thanks for joining!"
    )
    |> Mailer.normalize_addresses()
  end

  setup do
    System.put_env("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
    System.put_env("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    Application.put_env(:ex_aws, :http_client, ExAws.Request.HttpMock)
    :ok
  end

  test "delivers successfully" do
    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)
      assert EmailParser.from(email) == "bob@example.com"
      assert EmailParser.to(email) == ["alice@example.com"]
      assert EmailParser.reply_to(email) == "chuck@example.com"
      assert EmailParser.cc(email) == ["john@example.com"]
      assert EmailParser.subject(email) == "Welcome to the app."
      assert EmailParser.text(email).lines == ["Thanks for joining!", ""]
      assert EmailParser.html(email).lines == ["<strong>Thanks for joining!</strong>"]
      assert EmailParser.bcc(email) == ["jane@example.com"]
      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    SesAdapter.deliver(new_email(), %{})
  end

  test "delivers successfully with long subject" do
    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)
      subject_header = Enum.find(email.headers, &(&1.key == "subject"))

      assert subject_header.value ==
               "=?utf-8?B?#{Base.encode64("This is a long subject with an emoji 🙂 bla")}?= =?utf-8?B?#{
                 Base.encode64(" bla bla bla bla bla bla bla bla bla bla bla ")
               }?= =?utf-8?B?#{Base.encode64("bla bla bla bla")}?="

      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    SesAdapter.deliver(
      new_email(
        "alice@example.com",
        "This is a long subject with an emoji 🙂 bla bla bla bla bla bla bla bla bla bla bla bla bla bla bla bla"
      ),
      %{}
    )
  end

  test "delivers successfully email without body" do
    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)
      assert EmailParser.text(email) == nil
      assert EmailParser.html(email) == nil
      assert EmailParser.from(email) == "bob@example.com"
      assert EmailParser.to(email) == ["alice@example.com"]
      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    Email.new_email(from: "bob@example.com", to: "alice@example.com")
    |> Mailer.normalize_addresses()
    |> SesAdapter.deliver(%{})
  end

  test "delivers mails with dashes in top level domain successfully" do
    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)
      assert EmailParser.to(email) == ["jim@my-example-host.com"]

      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    SesAdapter.deliver(new_email("jim@my-example-host.com"), %{})
  end

  test "delivers attachments" do
    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)

      filenames =
        email
        |> EmailParser.attachments()
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert filenames == ["invoice.pdf", "song.mp3"]
      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    new_email()
    |> Email.put_attachment(Path.join(__DIR__, "../../../support/invoice.pdf"))
    |> Email.put_attachment(Path.join(__DIR__, "../../../support/song.mp3"))
    |> SesAdapter.deliver(%{})
  end

  test "passes content_id to attachment headers" do
    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)
      assert [attachment] = email |> EmailParser.attachments() |> Map.values()
      assert header = Enum.find(attachment.headers, &(&1.key == "content-id"))
      assert header.value == "invoice-pdf-1"

      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)
    path = Path.join(__DIR__, "../../../support/invoice.pdf")

    new_email()
    |> Email.put_attachment(path, content_id: "invoice-pdf-1")
    |> SesAdapter.deliver(%{})
  end

  test "sets the configuration set" do
    expected_configuration_set_name = "some-configuration-set"

    expected_request_fn = fn _, _, body, _, _ ->
      configuration_set_name =
        body
        |> URI.decode_query()
        |> Map.get("ConfigurationSetName")

      assert configuration_set_name == expected_configuration_set_name
      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    new_email()
    |> SesAdapter.set_configuration_set(expected_configuration_set_name)
    |> SesAdapter.deliver(%{})
  end

  test "sets the tags" do
    tag = %{key: "environment", value: "test"}
    expected_template = "some-template-set"

    expected_request_fn = fn _, _, body, _, _ ->
      query = URI.decode_query(body)

      # test that tag is present in request
      key = Map.get(query, "Tags.member.1.Key")
      value = Map.get(query, "Tags.member.1.Value")
      assert key == tag.key
      assert value == tag.value

      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    new_email()
    |> Bamboo.Email.put_private(:tags, [tag])
    |> SesAdapter.deliver(%{})
  end

  test "puts headers" do
    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)

      assert header = EmailParser.header(email, "x-custom-header")
      assert header.raw == "X-Custom-Header: header-value; another-value"
      assert EmailParser.reply_to(email) == "chuck@example.com"

      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    new_email()
    |> Email.put_header("X-Custom-Header", "header-value; another-value")
    |> SesAdapter.deliver(%{})
  end

  test "uses default aws region" do
    expected_request_fn = fn _, "https://email.us-east-1.amazonaws.com/", _, _, _ ->
      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    SesAdapter.deliver(new_email(), %{})
  end

  test "uses configured aws region" do
    expect(HttpMock, :request, fn _, "https://email.eu-west-1.amazonaws.com/", _, _, _ ->
      {:ok, %{status_code: 200}}
    end)

    SesAdapter.deliver(new_email(), %{ex_aws: [region: "eu-west-1"]})
  end

  test "returns error" do
    expect(HttpMock, :request, fn _, _, _, _, _ -> {:ok, %{status_code: 404}} end)

    {:error, %{message: msg}} = SesAdapter.deliver(new_email(), %{})
    assert msg == "{:http_error, 404, %{status_code: 404}}"
  end

  test "friendly name encoding" do
    email =
      Email.new_email(
        to: {"Alice Johnson", "alice@example.com"},
        from: {"Bob McBob", "bob@example.com"},
        headers: %{"Reply-To" => {"Chuck (?) Eager", "chuck@example.com"}},
        cc: {"John Müller", "john@example.com"},
        bcc: {"Jane \"The Builder\" Doe", "jane@example.com"},
        subject: "Welcome to the app this is a longer subject"
      )
      |> Mailer.normalize_addresses()

    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)
      assert EmailParser.to(email) == [~s("Alice Johnson" <alice@example.com>)]
      assert EmailParser.from(email) == ~s("Bob McBob" <bob@example.com>)

      assert EmailParser.cc(email) == [
               ~s("=?utf-8?B?#{Base.encode64("John Müller")}?=" <john@example.com>)
             ]

      assert EmailParser.bcc(email) == [
               ~s("=?utf-8?B?#{Base.encode64("Jane \"The Builder\" Doe")}?=" <jane@example.com>)
             ]

      assert EmailParser.reply_to(email) ==
               ~s("=?utf-8?B?#{Base.encode64("Chuck (?) Eager")}?=" <chuck@example.com>)

      assert EmailParser.subject(email) ==
               "Welcome to the app this is a longer subject"

      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    SesAdapter.deliver(email, %{})
  end

  test "punycode" do
    email =
      Email.new_email(
        to: "alice@möhren.de",
        cc: "bob@rüben.de",
        from: "someone@example.com"
      )
      |> Mailer.normalize_addresses()

    expected_request_fn = fn _, _, body, _, _ ->
      email = EmailParser.parse(body)
      assert EmailParser.to(email) == ["alice@xn--mhren-jua.de"]
      assert EmailParser.cc(email) == ["bob@xn--rben-0ra.de"]

      {:ok, %{status_code: 200}}
    end

    expect(HttpMock, :request, expected_request_fn)

    SesAdapter.deliver(email, %{})
  end
end
