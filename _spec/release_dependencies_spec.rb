require 'logging'

# need to create the logger prior to loading the engine module to avoid errors when the code
# tries to access the logger
Logging.init :trace, :debug, :verbose, :info, :warn, :error, :fatal
$LOG = Logging.logger.new 'awestruct'
$LOG.add_appenders(
		Logging.appenders.stdout({level: :info,
									layout: Logging.layouts.pattern(pattern: "%m\n", format_as: :string),
									color_scheme: :default})
)
$LOG.level = :info

require_relative '../_ext/release_file_parser'

describe Awestruct::Extensions::ReleaseDependencies do

  before :all do
    site_dir = File.join(File.dirname(__FILE__), '..')
    opts = Awestruct::CLI::Options.new
    opts.source_dir = site_dir
    @config = Awestruct::Config.new( opts )

    @engine = Awestruct::Engine.new( @config )
    @engine.load_default_site_yaml
    @engine.load_user_site_yaml( 'production' )

    @deps = [
      Awestruct::Extensions::ReleaseDependencies.new(@engine.site, 'org.hibernate', 'hibernate-core', '4.0.0.Beta1'),
      Awestruct::Extensions::ReleaseDependencies.new(@engine.site, 'org.hibernate', 'hibernate-search-parent', '3.4.0.Final'),
      Awestruct::Extensions::ReleaseDependencies.new(@engine.site, 'org.hibernate', 'hibernate-search', '3.4.0.Final')
    ]
  end

  describe "#initalize" do
    it 'raises error when pom cannot be accessed for production profile' do
      expect { Awestruct::Extensions::ReleaseDependencies.new(@engine.site, 'org.hibernate', 'hibernate-core', '0.Final') }
      .to raise_error(/Aborting site generation, since the production build requires the release POM information/)
    end
  end

  describe "#get_value" do
    context "pom w/o properties" do
      it "results in no properties" do
        expect(@deps[0].get_value('project.build.sourceEncoding')).to be_nil
      end
    end
    context "pom w/ properties" do
      it "allows to retrieve property value" do
        expect(@deps[1].get_value('project.build.sourceEncoding')).to eql 'UTF-8'
      end
    end
  end

  describe "#get_version" do
    it "retrieve direct version" do
      expect(@deps[0].get_version('junit', 'junit')).to eql '4.8.2'
    end

    it "retrieve variable version" do
      expect(@deps[2].get_version('org.hibernate', 'hibernate-core')).to eql '3.6.3.Final'
    end
  end
end
