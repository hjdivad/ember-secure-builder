require 'uri'
require 'spec_helper'

module EmberSecureBuilder
  describe "Rack Post-Receive Server :-P" do
    let(:server) { RackApp.new }
    let(:mock_payload) { File.read('spec/support/sample_github_payload.json') }

    after do
      AssetBuildingWorker.jobs.clear
    end

    describe "should not add job to queue when no payload was received" do
      it "should reply with a rude message on GET" do
        assert_equal 0, AssetBuildingWorker.jobs.size

        req = Rack::MockRequest.new(server)
        res = req.get("/")

        assert res.ok?

        assert_equal 0, AssetBuildingWorker.jobs.size
      end

      it "should reply with a rude message on POST without a payload" do
        assert_equal 0, AssetBuildingWorker.jobs.size

        req = Rack::MockRequest.new(server)
        res = req.post("/", {})

        assert res.ok?

        assert_equal 0, AssetBuildingWorker.jobs.size
      end
    end

    it "should reply with a nice message on POST with a payload" do
      assert_equal 0, AssetBuildingWorker.jobs.size

      req = Rack::MockRequest.new(server)

      post_body = URI.encode_www_form(:payload => mock_payload)
      res = req.post("/", :input => post_body)

      assert res.ok?

      assert_equal 1, AssetBuildingWorker.jobs.size
    end
  end
end
