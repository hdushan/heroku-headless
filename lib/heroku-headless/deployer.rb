require 'pathname'
require 'tmpdir'
require 'rendezvous'

module HerokuHeadless
  class Deployer
    include DocumentsActions
    include TalksToHeroku

    def self.deploy(app_name)
      new(app_name,CreatesUIDs.generate_uid).deploy
    end

    def initialize( app_name, uid )
      @app_name = app_name
      @uid = uid
    end

    def deploy
      prep_temp_dir
      setup_ssh_key
      result = do_action('push git to heroku'){ push_head_to_app }
      result = result && do_action('post_deploy_hooks'){ run_post_deploy_hooks }
      if HerokuHeadless.configuration.restart_processes
        result = result && do_action('restart_processes'){ restart_processes }
      end
      result
    ensure
      cleanup
    end

    private

    def prep_temp_dir
      @tmpdir = Pathname.new( Dir.tmpdir ).join('heroku-deployer').join(@uid)
      @tmpdir.mkpath
    end

    def cleanup
      do_action( 'removing ssh key' ){ remove_ssh_key }
      do_action( 'removing temp dir' ){ remove_temp_dir }
    end

    def remove_temp_dir
      @tmpdir.rmtree
    end

    def setup_ssh_key
      do_action( 'creating ssh key' ){ create_ssh_key }
      do_action( 'adding ssh key' ){ add_ssh_key }
    end

    def create_ssh_key
      `ssh-keygen -t rsa -N "" -C #{ssh_key_name} -f #{ssh_key_path}`
    end

    def ssh_key_path
      @tmpdir.join('id_rsa')
    end

    def ssh_key_name
      "deployer-#{@uid}"
    end

    def public_ssh_key
      ssh_key_path.sub_ext('.pub').read
    end

    def add_ssh_key
      heroku.post_key(public_ssh_key)
    end

    def remove_ssh_key
      heroku.delete_key(ssh_key_name)
    end

    def push_head_to_app
      setup_custom_git_ssh
      run_pre_deploy_git_commands
      push_git
    end

    def setup_custom_git_ssh
     custom_git_ssh_path.open('w') do |f|
       f.write <<-EOF
         #!/bin/sh
         exec ssh -o StrictHostKeychecking=no -o CheckHostIP=no -o UserKnownHostsFile=/dev/null -i #{ssh_key_path.expand_path} -- "$@"
       EOF
     end
     custom_git_ssh_path.chmod( 0740 )
    end

    def push_git
      system( {'GIT_SSH'=>custom_git_ssh_path.to_s}, git_push_command )
    end

    def git_push_command
      cmd = "git push "
      cmd << "-f " if HerokuHeadless.configuration.force_push
      #cmd << "git@heroku.com:#{@app_name}.git HEAD:refs/heads/master"
      cmd << "-u git@heroku.com:#{@app_name}.git HEAD:refs/heads/master"
    end

    def run_pre_deploy_git_commands
      HerokuHeadless.configuration.pre_deploy_git_commands.each do | command |
        do_action( command ) { run_git_command(command) }
      end
    end
    def run_git_command(command)
      result = system( {'GIT_SSH'=>custom_git_ssh_path.to_s}, command )
      result
    end

    def run_post_deploy_hooks
      HerokuHeadless.configuration.post_deploy_commands.each do | command |
        do_action( command ){ run_command(command) }
      end
    end

    def restart_processes
      response = heroku.post_ps_restart(@app_name)
      response.body == "ok"
    end

    def run_command(cmd)
      data = heroku.post_ps(@app_name, cmd, :attach => true).body
      rendezvous_url = data['rendezvous_url']
      Rendezvous.start(:url => rendezvous_url) unless rendezvous_url.nil?
    end

    def custom_git_ssh_path
      @tmpdir.join('git-ssh')
    end
  end
end
