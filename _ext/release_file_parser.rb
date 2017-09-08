require 'nokogiri'
require 'open-uri'
require 'uri'
require 'fileutils'

module Awestruct
  module Extensions
    # Awestrcut extension which traverses the given directory to find release information,
    # making it available in a hash.
    #
    # The assumption is that the parent directory is named after the project,
    # and release files are YAML files in a direct subdirectory called 'releases'.
    #
    # The release information for a given release can then be accessed, starting from the
    # top level site hash via:
    # site['projects'].['<project-name>'].['releases'].['<release-version>'], eg site['projects'].['validator'].['releases'].['5.0.0.Final'].
    #
    # The release data itself is stored in the hash using at the moment the following keys:
    # version, version_family, date, stable, announcement_url, summary and displayed
    class ReleaseFileParser

      def initialize(data_dir="_data")
        @data_dir = data_dir
      end

      def watch(watched_dirs)
        watched_dirs << @data_dir
      end

      def execute(site)
        # keep reference to site
        @site = site

        # register the parent hash for all releases with the site
        @projects_hash = site[:projects]
        if @projects_hash == nil
           @projects_hash = Hash.new
           site[:projects] = @projects_hash
        end

        # traverse the file system to find the release information
        findReleaseFiles( site, "#{site.dir}/#{@data_dir}" )
      end

      def findReleaseFiles(site, dir)
        Dir[ "#{dir}/*" ].each do |entry|
          if ( File.directory?( entry ) )
            if ( entry =~ /releases/ )
              project = getProject( entry )
              default_group_id, artifact_id = getDefaultGAInfo( site, project[:id] )

              releases_hash = project[:releases]
              if ( releases_hash == nil )
                releases_hash = Hash.new
                project[:releases] = releases_hash
              end
              
              release_series_hash = project[:release_series]
              if ( release_series_hash == nil )
                release_series_hash = Hash.new
                project[:release_series] = release_series_hash
              end

              populateReleaseHashes( entry, release_series_hash, releases_hash )
              
              sortReleaseHashes( project )
              
              downloadDependencies( release_series_hash.values, default_group_id, artifact_id )
            else
              findReleaseFiles( site, entry )
            end
          end
        end
      end
      
      def getProject(sub_dir)
        parent_dir = File.dirname( sub_dir )
        project_id = File.basename( parent_dir )

        project = @projects_hash[project_id]
        if project == nil
          project = Hash.new
          @projects_hash[project_id] = project
        end
        
        if (project[:id] == nil)
          project[:id] = project_id
        end
        
        return project
      end

      def getDefaultGAInfo(site, project_name)
        # we can't rely on the artifact_id from site as the one for OGM is hibernate-ogm-*
        case project_name
          when 'ogm'
            default_group_id = site.projects[project_name].group_id
            artifact_id = 'hibernate-ogm-core'
          when 'orm'
            default_group_id = site.projects[project_name].group_id
            artifact_id = 'hibernate-core'
          when 'search'
            default_group_id = site.projects[project_name].group_id
            artifact_id = 'hibernate-search'
          when 'validator'
            default_group_id = site.projects[project_name].group_id
            artifact_id = 'hibernate-validator'
        end

        return default_group_id, artifact_id
      end

      def populateReleaseHashes(releases_dir, release_series_hash, release_hash)
        Dir.foreach(releases_dir) do |file_name|
          file = File.expand_path( file_name, releases_dir )
          if ( File.directory?( file ) )
            # skip '.' and '..'
            if ( file_name.start_with?( "." ) )
              next
            else
              # This directory represents a release series
              series = createSeries( file )
              release_series_hash[series.version] = series

              # Populate this series' releases
              Dir.foreach(file) do |sub_file_name|
               sub_file = File.expand_path( sub_file_name, file )
                # skip '.' and '..' and 'series.yml'
                if ( File.directory?( sub_file ) || File.basename( sub_file ) == "series.yml" )
                  next
                else
                  release = createRelease( sub_file, series )
                  series.releases.push( release )
                  release_hash[release.version] = release
                end
              end
            end
          else
            # Old-style release files, directly at the root, with no series info
            # TODO remove this code if all projects migrate to the "series" paradigm
            release = createRelease( file, nil )
            release_hash[release.version] = release
            # Add a minimal series from the information we can get
            series_version = release.version_family.to_s # to_s is necessary, some files use symbols instead of strings
            series = release_series_hash[series_version]
            if ( series == nil ) 
              series = OpenStruct.new
              release_series_hash[series_version] = series
              series[:version] = series_version
              series[:releases] = Array.new
            end
            series[:displayed] ||= release.displayed
            series.releases.push( release )
          end
        end
      end

      def createSeries(series_dir)
        series_file = File.expand_path( "./series.yml", series_dir )
        series = @site.engine.load_yaml( series_file )
        if ( series[:version] == nil )
          series[:version] = File.basename( series_dir )
        end
        series[:releases] = Array.new
        return series
      end

      def createRelease(release_file, series)
        unless ( release_file =~ /.*\.yml$/ )
          abort( "The release file #{release_file} does not have the YAML (.yml) extension!" )
        end

        release = @site.engine.load_yaml( release_file )
        
        if ( release[:version] == nil )
          File.basename( release_file ) =~ /^(.*)\.\w*$/
          release[:version] = $1
        end
        if ( series != nil )
          release[:version_family] = series.version
        end
        
        return release
      end

      def sortReleaseHashes(project)
        releases = project[:releases]
        unless releases == nil
          project[:releases] = Hash[releases.sort_by { |key, value| Version.new(key) }.reverse]
          project[:sorted_releases] = project[:releases].values
        end
        series = project[:release_series]
        unless series == nil
          project[:release_series] = Hash[series.sort_by { |key, value| Version.new(key) }.reverse]
          series.each do |series_version, series|
            releases = series.releases
            series.releases = releases.sort_by { |release| Version.new(release.version) }.reverse
          end
        end
      end

      def downloadDependencies(series, default_group_id, artifact_id)
        series.each do |series|
          if ( default_group_id != nil && artifact_id != nil && series.displayed != false)
            # Only download dependencies for the latest release in the series
            release = series.releases[0]
            group_id = (release.group_id? ? release.group_id : default_group_id)
            release.dependencies = ReleaseDependencies.new(@site, group_id, artifact_id, release.version)
          end
        end
      end
    end
            
    # Custom version class able to understand and compare the project versions of Hibernate projects
    class Version
      include Comparable

      attr_reader :major, :feature_group, :feature, :bugfix

      def initialize(version="")
        v = version.to_s.split(".")
        @major = v[0].to_i
        @feature_group = v[1].to_i
        @feature = v[2].to_i
        @bugfix = v[3].to_s
      end

      def <=>(other)
        return @major <=> other.major if ((@major <=> other.major) != 0)
        return @feature_group <=> other.feature_group if ((@feature_group <=> other.feature_group) != 0)
        return @feature <=> other.feature if ((@feature <=> other.feature) != 0)
        return @bugfix <=> other.bugfix
      end

      def self.sort
        self.sort!{|a,b| a <=> b}
      end

      def to_s
        @major.to_s + "." + @feature_group.to_s + "." + @feature.to_s + "." + @bugfix.to_s
      end
    end

    # Helper class to retrieve the dependencies of a release by parsing the release POM
    class ReleaseDependencies
      Nexus_base_url = 'https://repository.jboss.org/nexus/content/repositories/public/'

      def initialize(site, group_id, artifact_id, version)
        # init instance variables
        @properties = Hash.new
        @dependencies = Hash.new
        @site = site

        # try loading the pom
        uri = get_uri(group_id, artifact_id, version)
        doc = create_doc(uri)
        unless doc == nil
          if has_parent(doc)
            # parent pom needs to be loaded first
            parent_uri = get_uri(doc.xpath('//parent/groupId').text, doc.xpath('//parent/artifactId').text, doc.xpath('//parent/version').text)
            parent_doc = create_doc(parent_uri)
            process_doc(parent_doc)
          end
          process_doc(doc)
        end
      end

      def get_value(property)
        @properties[property]
      end

      def get_version(group_id, artifact_id)
        @dependencies[group_id + ':' + artifact_id]
      end

      private
      def create_doc(uri)
        # make sure _tmp dir exists
        tmp_dir = File.join(File.dirname(__FILE__), '..', '_tmp')
        unless File.directory?(tmp_dir)
          p "creating #{tmp_dir}"
          FileUtils.mkdir_p(tmp_dir)
        end

        pom_name = uri.sub(/.*\/([\w\-\.]+\.pom)$/, '\1')
        # to avoid net access cache the downloaded POMs into the _tmp directory
        cached_pom = File.join(tmp_dir, pom_name)
        if File.exists?(cached_pom)
          $LOG.info "Cache hit: #{uri.to_s}" if $LOG.info?
          f = File.open(cached_pom)
          doc = Nokogiri::XML(f)
          f.close
        else
          begin
            $LOG.info "Downloading: #{uri.to_s}" if $LOG.info?
            doc = Nokogiri::XML(open(uri))
            # cache the pom
            File.open(cached_pom, 'w') { |f| f.print(doc.to_xml) }
          rescue => error
            $LOG.warn "Release POM #{uri.split('/').last} not locally cached and unable to retrieve it from JBoss Nexus"
            if @site.profile == 'production'
              abort "Aborting site generation, since the production build requires the release POM information"
            else
              $LOG.warn "Continue build since we are building the '#{@site.profile}' profile. Note that variables interpolated from the release poms will not display\n"
              return nil
            end
          end
        end
        doc.remove_namespaces!
      end

      def process_doc(doc)
        load_properties(doc)
        extract_dependencies(doc)
      end

      def get_uri(group_id, artifact, version)
        Nexus_base_url + group_id.gsub(/\./, "/") + '/' + artifact + '/' + version + '/' + artifact + '-' + version + '.pom'
      end

      def has_parent(doc)
        !doc.xpath('//parent').empty?
      end

      def load_properties(doc)
        doc.xpath('//properties/*') .each do |property|
          key = property.name
          value = property.text
          @properties[key] = value
        end
      end

      def extract_dependencies(doc)
        doc.xpath('//dependency') .each do |dependency|
          group_id = dependency.xpath('./groupId').text
          artifact_id = dependency.xpath('./artifactId').text
          version = dependency.xpath('./version').text
          if ( version =~ /\$\{(.*)\}/ )
            version = @properties[$1]
          end
          key = group_id + ':' + artifact_id
          if @dependencies[key] == nil
            @dependencies[key] = version
          end
        end
      end
    end
  end
end
