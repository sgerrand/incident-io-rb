# frozen_string_literal: true

require "socket"

# These examples use a real socket. WebMock stubs replace the part of
# Net::HTTP that re-sends a request by itself, so they can't show it.
RSpec.describe IncidentIo::Transport::NetHTTP do
  subject(:transport) { described_class.new }

  let(:server) { TCPServer.new("127.0.0.1", 0) }
  let(:connections) { [] }

  # A server that accepts connections and never answers, so every request
  # times out.
  around do |example|
    WebMock.disable_net_connect!(allow_localhost: true)
    acceptor = Thread.new { loop { connections << server.accept } }
    example.run
  ensure
    acceptor&.kill
    connections.each(&:close)
    server.close
    WebMock.disable_net_connect!
  end

  def request(method)
    IncidentIo::Request.new(
      method:,
      url: "http://127.0.0.1:#{server.addr[1]}/v2/incidents",
      headers: {},
      body: nil,
      timeout: 0.1,
      open_timeout: 1
    )
  end

  %i[get put delete].each do |method|
    it "sends a #{method.upcase} that times out only once" do
      expect { transport.call(request(method)) }.to raise_error(IncidentIo::APITimeoutError)
      expect(connections.size).to eq(1)
    end
  end
end
