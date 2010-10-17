require 'rack/cache'
require 'dragonfly'
require 'refinery'

module Refinery
  module Images
    class Engine < Rails::Engine
      initializer 'fix-tempfile-not-closing-with-dragonfly-images' do |app|
        # see http://github.com/markevans/dragonfly/issues#issue/18/comment/415807
        require 'tempfile'
        class Tempfile

          def unlink
            # keep this order for thread safeness
            begin
              if File.exist?(@tmpname)
                closed? or close
                File.unlink(@tmpname)
              end
              @@cleanlist.delete(@tmpname)
              @data = @tmpname = nil
              ObjectSpace.undefine_finalizer(self)
            rescue Errno::EACCES
              # may not be able to unlink on Windows; just ignore
            end
          end

        end
      end

      initializer 'images-with-dragonfly' do |app|
        app_images = Dragonfly[:images]
        app_images.configure_with(:rmagick)
        app_images.configure_with(:rails) do |c|
          c.datastore.root_path = Rails.root.join('public', 'system', 'images').to_s
          c.url_path_prefix = '/system/images'
          if RefinerySetting.table_exists?
            c.secret = RefinerySetting.find_or_set(:dragonfly_secret,
                                                   Array.new(24) { rand(256) }.pack('C*').unpack('H*').first)
          end
        end
        app_images.configure_with(:heroku, ENV['S3_BUCKET']) if Refinery.s3_backend

        app_images.define_macro(ActiveRecord::Base, :image_accessor)
        app_images.analyser.register(Dragonfly::Analysis::RMagickAnalyser)
        app_images.analyser.register(Dragonfly::Analysis::FileCommandAnalyser)

        # This eval makes it so that dragonfly urls work in traditional
        # situations where the filename and extension are required, e.g. lightbox.
        # What this does is takes the url that is about to be produced e.g.
        # /system/images/BAhbB1sHOgZmIiMyMDEwLzA5LzAxL1NTQ19DbGllbnRfQ29uZi5qcGdbCDoGcDoKdGh1bWIiDjk0MngzNjAjYw
        # and adds the filename onto the end (say the image was 'refinery_is_awesome.jpg')
        # /system/images/BAhbB1sHOgZmIiMyMDEwLzA5LzAxL1NTQ19DbGllbnRfQ29uZi5qcGdbCDoGcDoKdGh1bWIiDjk0MngzNjAjYw/refinery_is_awesome.jpg
        # from: http://markevans.github.com/dragonfly/file.URLs.html
        app_images.url_suffix = proc{|job|
          "/#{job.uid_basename}#{job.encoded_extname || job.uid_extname}"
        }

        ### Extend active record ###

        app.config.middleware.insert_after 'Rack::Lock', 'Dragonfly::Middleware', :images, '/system/images'

        app.config.middleware.insert_before 'Dragonfly::Middleware', 'Rack::Cache', {
          :verbose     => Rails.env == "development"
          :metastore   => "file:#{Rails.root.join('tmp', 'dragonfly', 'cache', 'meta')}",
          :entitystore => "file:#{Rails.root.join('tmp', 'dragonfly', 'cache', 'body')}"
        }
      end

      config.after_initialize do
        Refinery::Plugin.register do |plugin|
          plugin.name = "refinery_images"
          plugin.directory = "images"
          plugin.version = %q{0.9.8}
          plugin.menu_match = /(refinery|admin)\/image(_dialog)?s$/
          plugin.activity = {
            :class => Image
          }
        end
      end
    end
  end
end
