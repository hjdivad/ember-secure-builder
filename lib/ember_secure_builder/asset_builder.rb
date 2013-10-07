require 'tmpdir'
require 'fileutils'

module EmberSecureBuilder
  class AssetBuilder
    attr_accessor :suspect_repo, :suspect_branch,
                  :good_repo,    :good_branch,
                  :work_dir,     :debug, :env,
                  :asset_source_path, :asset_destination_path,
                  :pull_request_number, :last_suspect_repo_commit

    def self.publish_pull_request(repository, pull_request_number, perform_cross_browser_tests = false)
      builder = new
      builder.load_from_pull_request(repository, pull_request_number)
      builder.build
      builder.publish
    end

    def self.publish(options = nil)
      builder = new(options)
      builder.build
      builder.upload
    end

    def initialize(options = nil)
      options ||= {}

      self.env            = options.fetch(:env) { ENV }
      self.suspect_repo   = options.fetch(:suspect_repo, nil)
      self.suspect_branch = options.fetch(:suspect_branch, nil)

      self.good_repo   = options.fetch(:good_repo) {  'https://github.com/emberjs/ember.js.git' }
      self.good_branch = options.fetch(:good_branch) {  'master' }

      self.debug       = options.fetch(:debug) { true }
      self.work_dir    = options.fetch(:work_dir) { build_work_dir }

      self.asset_source_path      = options[:asset_source_path]
      self.asset_destination_path = options[:asset_destination_path]
    end

    def load_from_pull_request(repo, pull_request_number)
      prefix = 'https://github.com/'

      require 'octokit'
      pr = Octokit.pull_request repo, pull_request_number

      self.suspect_repo             = prefix + pr.head.repo.full_name
      self.suspect_branch           = pr.head.ref
      self.pull_request_number      = pull_request_number
      self.last_suspect_repo_commit = pr.head.sha
    end

    def last_suspect_repo_commit
      @last_suspect_repo_commit ||= begin
                                      prefix = 'https://github.com/'

                                      require 'octokit'
                                      branch = Octokit.branch suspect_repo.sub(prefix, ''), suspect_branch

                                      branch.commit.sha
                                    end
    end

    def cleanup
      FileUtils.remove_entry_secure work_dir if File.exists? work_dir
    end

    def clone_repos
      @cloned ||= clone_suspect_repo && clone_good_repo
    end

    def copy_suspect_packages
      clone_repos

      FileUtils.rm_r good_repo_local_path.join('packages')
      FileUtils.cp_r suspect_repo_local_path.join('packages').to_s, good_repo_local_path.to_s
    end

    def build
      clone_repos

      Dir.chdir good_repo_local_path do
        Bundler.with_clean_env do
          system('bundle install && bundle exec rake dist ember:generate_static_test_site')
        end
      end
    end

    def asset_source_path
      @asset_source_path ||= good_repo_local_path.join('dist')
    end

    def asset_destination_path
      @asset_destination_path ||= 'somepath'
    end

    def upload(options = {})
      bucket = options.fetch(:bucket) { build_s3_bucket }

      files = %w{ember.js ember-spade.js ember-tests.js tests.html}

      files.each do |file|
        type = file.end_with?('.js') ? 'text/javascript' : 'text/html'

        obj = bucket.objects[asset_destination_path + "/#{file}"]
        obj.write(asset_source_path.join(file), {:content_type => type})
      end
    end

    def queue_cross_browser_tests(options = nil)
      options    ||= {}
      platforms    = options.fetch(:platforms) { SauceLabsWebdriverJob.default_platforms }
      worker_class = options.fetch(:worker_class) { SauceLabsWorker }
      test_url     = options.fetch(:test_url) { build_test_url }
      build        = options.fetch(:build) { last_suspect_repo_commit }
      name         = options.fetch(:name) { "PR #{pull_request_number}" }

      platforms.each do |platform|
        worker_class.perform_async(platform.merge(:url   => test_url,
                                                  :name  => name,
                                                  :build => build))
      end
    end

    private

    def build_test_url
      "https://s3.amazonaws.com/#{bucket_name}/#{asset_destination_path}/tests.html"
    end

    def clone_suspect_repo
      clone_repo suspect_repo, suspect_branch, suspect_repo_local_path
    end

    def clone_good_repo
      clone_repo good_repo, good_branch, good_repo_local_path
    end


    def good_repo_local_path
      work_dir.join('good')
    end

    def suspect_repo_local_path
      work_dir.join('suspect')
    end

    def clone_repo(url, branch, path)
      command = "git clone --quiet --depth=1 --branch=#{branch} #{url} #{path}"

      puts command if debug
      system(command)
    end

    def build_work_dir
      dir = Dir.mktmpdir

      at_exit{ cleanup }

      Pathname.new(dir)
    end

    def bucket_name
      @bucket_name ||= env['S3_BUCKET_NAME']
    end

    def build_s3_bucket
      s3 = AWS::S3.new(:access_key_id => env['S3_ACCESS_KEY_ID'],
                       :secret_access_key => env['S3_SECRET_ACCESS_KEY'])

      s3.buckets[bucket_name]
    end
  end
end
