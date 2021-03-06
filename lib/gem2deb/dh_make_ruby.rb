# Copyright © 2011, Lucas Nussbaum <lucas@debian.org>
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'gem2deb'
require 'gem2deb/metadata'
require 'rubygems'
require 'yaml'
require 'fileutils'
require 'erb'

module Gem2Deb

  class DhMakeRuby

    include Gem2Deb

    EMAIL_REGEXP = /^(.*)\s+<(.*)>$/

    attr_accessor :gem_name

    attr_accessor :gem_version

    attr_accessor :metadata

    attr_reader :source_package_name

    def source_package_name=(value)
      @source_package_name = value.gsub('_', '-')
    end

    attr_accessor :source_tarball_name

    attr_accessor :orig_tarball_name

    attr_accessor :orig_tarball_dir

    def initialize(tarball, options = {})
      self.source_tarball_name = File.basename(tarball)
      self.orig_tarball_dir = File.dirname(tarball)

      options.each do |attr,value|
        self.send("#{attr}=", value)
      end

      if source_tarball_name =~ /^(.*)_(.*).orig.tar.gz$/
        self.gem_name = $1
        self.gem_version = $2
        self.source_package_name ||= gem_name # assume orig.tar.gz was previously prepared and is already correct
        self.orig_tarball_name = source_tarball_name
      elsif source_tarball_name =~ /^(.*)-(.*).tar.gz$/
        self.gem_name = $1
        self.gem_version = $2
        self.source_package_name ||= 'ruby-' + gem_name.gsub(/^ruby[-_]|[-_]ruby$/, '')
        self.orig_tarball_name = "#{source_package_name}_#{gem_version}.orig.tar.gz"
      else
        raise "Could not determine gem name and version from tarball #{source_tarball_name}"
      end
    end

    def gem_dirname
      [gem_name, gem_version].join('-')
    end

    def source_dirname
      [source_package_name, gem_version].join('-')
    end

    def binary_packages
      @binary_packages ||= []
    end

    def homepage
      metadata.homepage
    end

    def short_description
      metadata.short_description
    end

    def long_description
      metadata.long_description
    end

    def build
      Dir.chdir(orig_tarball_dir) do
        create_orig_tarball
        extract
        Dir.chdir(source_dirname) do
          read_upstream_source_info
          create_debian_boilerplates
          other_files
          test_suite
        end
      end
    end
    
    def read_upstream_source_info
      read_metadata
      detect_needed_binary_packages
    end

    def read_metadata
      self.metadata = Gem2Deb::Metadata.new('.')
    end

    def detect_needed_binary_packages
      binary_packages << Package.new(source_package_name)
      if metadata.has_native_extensions?
        binary_packages << Package.new(source_package_name.sub('ruby-', 'ruby1.8-'))
        binary_packages << Package.new(source_package_name.sub('ruby-', 'ruby1.9.1-'))
      end

      binary_packages.each do |package|
	metadata.dependencies.each do |dependency|
	  package.gem_dependencies << dependency
	end
      end

      binary_packages
    end

    def buildpackage(source_only = false, check_build_deps = true)
      dpkg_buildpackage_opts = []
      dpkg_buildpackage_opts << '-S' if source_only
      dpkg_buildpackage_opts << '-d' unless check_build_deps

      Dir.chdir(source_dirname) do
        run("dpkg-buildpackage -us -uc #{dpkg_buildpackage_opts.join(' ')}")
      end
    end

    def create_orig_tarball
      if source_package_name != orig_tarball_name && !File.exists?(orig_tarball_name)
        run "ln -s #{source_tarball_name} #{orig_tarball_name}"
      end
    end

    def extract
      run("tar xzf #{orig_tarball_name}")
      if !File.directory?(gem_dirname)
        raise "Extracting did not create #{gem_dirname} directory."
      end
      if gem_dirname != source_dirname && !File.exists?(source_dirname)
        FileUtils.mv gem_dirname, source_dirname
      end
    end

    def create_debian_boilerplates
      FileUtils.mkdir_p('debian')
      unless File.exists?('debian/changelog')
        run "dch --create --empty --fromdirname 'Initial release (Closes: #nnnn)'"
      end
      templates.each do |template|
        FileUtils.mkdir_p(template.directory)
        File.open(template.filename, 'w') do |f|
          f.puts ERB.new(template.data, nil, '<>').result(binding)
        end
      end
      FileUtils.chmod 0755, 'debian/rules'
    end

    def templates
      @templates ||= Template.load
    end

    class Template
      attr_accessor :filename
      attr_accessor :data

      TEMPLATES_FILE = File.expand_path(__FILE__)

      def self.load
        result = []
        File.read(TEMPLATES_FILE).gsub(/.*__END__\n/m, '').lines.each do |line|
          if line =~ /^>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> (.*)/
            filename = $1
            result << Template.new(filename)
          else
            result.last.data << line
          end
        end
        result
      end

      def initialize(filename)
        self.filename = filename
        self.data = ''
      end

      def directory
        File.dirname(filename)
      end
    end

    ##
    # Try to find the maintainer from ENV
    # logic translated from perl in package « devscripts: /usr/bin/dch »
    #
    def maintainer
      debenv = {}
      # defaults
      debenv['DEBFULLNAME'] = ENV['DEBFULLNAME']
      debenv['DEBEMAIL'] = ENV['DEBEMAIL'] || ENV['EMAIL']

      # DEBEMAIL is like "Full Name <email@host>"
      # extract DEBFULLNAME from it
      if ENV['DEBEMAIL'] && ENV['DEBEMAIL'] =~ EMAIL_REGEXP
        debenv['DEBFULLNAME'] = $1 if ENV['DEBFULLNAME'].nil?
        debenv['DEBEMAIL'] = $2
      end
      # dont have DEBEMAIL nor DEBFULLNAME from ENV
      # try with EMAIL
      if ENV['DEBEMAIL'].nil? || ENV['DEBFULLNAME'].nil?
        if ENV['EMAIL'] && ENV['EMAIL'] =~ EMAIL_REGEXP
          debenv['DEBFULLNAME'] = $1 if ENV['DEBFULLNAME'].nil?
          debenv['DEBEMAIL'] = $2
        end
      end
      debenv
    end

    class Package
      attr_accessor :name
      def initialize(name)
        self.name = name
      end
      def dependencies
        ['${shlibs:Depends}', '${misc:Depends}', 'ruby1.8 | ruby-interpreter' ]
      end
      def gem_dependencies
	@gem_dependencies ||= []
      end
      def architecture
        if name =~ /^ruby-/ || name !~ /ruby/
          'all'
        else
          'any'
        end
      end
    end

    def test_suite
      if !metadata.test_files.empty?
        File::open("debian/ruby-test-files.yaml", 'w') do |f|
          YAML::dump(metadata.test_files, f)
        end
      else
        if File::directory?("test") or File::directory?("spec")
          File::open("debian/ruby-tests.rb", 'w') do |f|
            f.puts <<-EOF
# FIXME
# there's a spec/ or a test/ directory in the upstream source, but
# no test suite was defined in the Gem specification. It would be
# a good idea to define it here so the package gets tested at build time.
# Examples:
# $: << 'lib' << '.'
# Dir['{spec,test}/**/*.rb'].each { |f| require f }
#
# require 'test/ts_foo.rb'
#
# require 'rbconfig'
# ruby = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
# exec("\#{ruby} -I. test/runtests.rb")
            EOF
          end
        end
      end
    end

    def other_files
      # docs
      docs = ""
      if File::directory?('doc')
        docs += <<-EOF
# FIXME: doc/ dir found in source. Consider installing the docs.
# Examples:
# doc/manual.html
# doc/site/*
            EOF
      end
      readmes = Dir::glob('README*')
      docs += <<-EOF
# FIXME: READMEs found
      EOF
      readmes.each do |r|
        docs << "# #{r}\n"
      end
      if docs != ""
        File::open("debian/#{source_package_name}.docs", 'w') do |f|
          f.puts docs
        end
      end

      # examples
      examples = ""
      ['examples', 'sample'].each do |d|
        if File::directory?(d)
          examples += <<-EOF
# FIXME: #{d}/ dir found in source. Consider installing the examples.
# Examples:
# #{d}/*
          EOF
        end
      end
      if examples != ""
        File::open("debian/#{source_package_name}.examples", 'w') do |f|
          f.puts examples
        end
      end

      # data & conf
      installs = ""
      if File::directory?('data')
        installs += <<-EOF
# FIXME: data/ dir found in source. Consider installing it somewhere.
# Examples:
# data/* /usr/share/#{source_package_name}/
        EOF
      end
      if File::directory?('conf')
        installs += <<-EOF
# FIXME: conf/ dir found in source. Consider installing it somewhere.
# Examples:
# conf/* /etc/
        EOF
      end
      if installs != ""
        File::open("debian/#{source_package_name}.install", 'w') do |f|
          f.puts installs
        end
      end

      # manpages
      if File::directory?('man')
        manpages = Dir.glob("man/**/*.[1-8]")
        manpages_header = "# FIXME: man/ dir found in source. Consider installing manpages"

        File::open("debian/#{source_package_name}.manpages", 'w') do |f|
          f.puts manpages_header
          manpages.each do |m|
            f.puts "# " + m
          end
        end
      end
    end
  end
end

__END__
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> debian/control
Source: <%= source_package_name %>
Section: ruby
Priority: optional
Maintainer: Debian Ruby Extras Maintainers <pkg-ruby-extras-maintainers@lists.alioth.debian.org>
Uploaders: <%= maintainer['DEBFULLNAME'] %> <<%= maintainer['DEBEMAIL'] %>>
DM-Upload-Allowed: yes
Build-Depends: debhelper (>= 7.0.50~), gem2deb (>= <%= Gem2Deb::VERSION %>)
Standards-Version: 3.9.1
#Vcs-Git: git://git.debian.org/pkg-ruby-extras/<%= source_package_name %>.git
#Vcs-Browser: http://git.debian.org/?p=pkg-ruby-extras/<%= source_package_name %>;a=summary
Homepage: <%= homepage ? homepage : 'FIXME'%>
<% binary_packages.each do |package| %>

Package: <%= package.name %>
Architecture: <%= package.architecture %>
Depends: <%= package.dependencies.join(', ') %>
<% if package.gem_dependencies.length > 0 %>
# <%= package.gem_dependencies.join(', ') %>
<% end %>
Description: <%= short_description ? short_description : 'FIXME' %>
<% if long_description %>
<%= long_description.lines.map { |line| ' ' + (line.strip.empty? ? '.' : line.strip) }.join("\n") + "\n" %>
<% else %>
<%= " <insert long description, indented with spaces>\n" %>
<% end %>
<% end %>
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> debian/rules
#!/usr/bin/make -f
#export DH_VERBOSE=1
#
# Uncomment to ignore all test failures
#export DH_RUBY_IGNORE_TESTS=all
#
# Uncomment to ignore some test failures. Valid values:
#export DH_RUBY_IGNORE_TESTS=ruby1.8 ruby1.9.1 require-rubygems

%:
	dh $@ --buildsystem=ruby
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> debian/compat
7
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> debian/copyright
FIXME. fill-in with DEP5 copyright file. http://dep.debian.net/deps/dep5/
Format: http://svn.debian.org/wsvn/dep/web/deps/dep5.mdwn?op=file&rev=173
Upstream-Name: <%= gem_name %>
Source: FIXME (URL where source can be downloaded)

Files: *
Copyright: Copyright 1998 John Doe <jdoe@example.com>
License: GPL-2+
 This program is free software; you can redistribute it
 and/or modify it under the terms of the GNU General Public
 License as published by the Free Software Foundation; either
 version 2 of the License, or (at your option) any later
 version.
 .
 This program is distributed in the hope that it will be
 useful, but WITHOUT ANY WARRANTY; without even the implied
 warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 PURPOSE.  See the GNU General Public License for more
 details.
 .
 You should have received a copy of the GNU General Public
 License along with this package; if not, write to the Free
 Software Foundation, Inc., 51 Franklin St, Fifth Floor,
 Boston, MA  02110-1301 USA
 .
 On Debian systems, the full text of the GNU General Public
 License version 2 can be found in the file
 `/usr/share/common-licenses/GPL-2'.

Files: debian/*
Copyright: Copyright 1998 Jane Smith <jsmith@example.net>
License:
 [LICENSE TEXT]
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> debian/watch
version=3
http://pkg-ruby-extras.alioth.debian.org/cgi-bin/gemwatch/<%= gem_name %> .*/<%= gem_name %>-(.*).tar.gz
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> debian/source/format
3.0 (quilt)
