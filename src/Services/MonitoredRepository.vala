// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
/*-
 * Copyright (c) 2020 elementary LLC. (https://elementary.io),
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License version 3
 * as published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranties of
 * MERCHANTABILITY, SATISFACTORY QUALITY, or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: Jeremy Wootten <jeremy@elementaryos.org>
 */

namespace Scratch.Services {
    public class MonitoredRepository : Object {
        public Ggit.Repository git_repo { get; set construct; }
        private FileMonitor? git_monitor = null;
        private FileMonitor? gitignore_monitor = null;
        private string _branch_name = "";
        public string branch_name {
            get {
                return _branch_name;
            }

            set {
                if (_branch_name != value) {
                    _branch_name = value;
                    branch_changed (value);
                }
            }
        }

        public signal void branch_changed (string name);
        public signal void file_status_change ();

        private uint update_timer_id = 0;

        // Map paths to status other than CURRENT
        // We use two maps alternately in order to detect modified files reverting to unmodified without copying maps.
        private Gee.HashMap<string, Ggit.StatusFlags> [] map_array;
        private int map_index = 0;
        private int old_map_index = 1;
        private Gee.HashMap<string, Ggit.StatusFlags> map_in_use {
            get {
                return map_array[map_index];
            }
        }

        private Gee.HashMap<string, Ggit.StatusFlags> old_map {
            get {
                return map_array[old_map_index];
            }
        }

        public Gee.Set<Gee.Map.Entry<string, Ggit.StatusFlags>> non_current_entries {
            owned get {
                return map_in_use.entries;
            }
        }

        construct {
            var file_status_map = new Gee.HashMap<string, Ggit.StatusFlags> ();
            var alt_file_status_map = new Gee.HashMap<string, Ggit.StatusFlags> ();
            map_array = {file_status_map, alt_file_status_map};
        }

        public MonitoredRepository (Ggit.Repository _git_repo) {
            git_repo = _git_repo;
            var git_folder = git_repo.get_location ();

            try {
                git_monitor = git_folder.monitor_directory (GLib.FileMonitorFlags.NONE);
                git_monitor.changed.connect (update);
            } catch (IOError e) {
                warning ("An error occured setting up a file monitor on the git folder: %s", e.message);
            }

            // We will only deprioritize git-ignored files whenever the project folder is a git_repo.
            // It doesn't make sense to have a .gitignore file in a project folder that ain't a local git repo.
            var workdir = git_repo.workdir;
            var gitignore_file = workdir.get_child (".gitignore");
            if (gitignore_file.query_exists ()) {
                try {
                    gitignore_monitor = gitignore_file.monitor_file (GLib.FileMonitorFlags.NONE);
                    gitignore_monitor.changed.connect (update);
                } catch (IOError e) {
                    warning ("An error occured setting up a file monitor on the gitignore file: %s", e.message);
                }
            }
        }

        ~MonitoredRepository () {
            if (git_monitor != null) {
                git_monitor.cancel ();
            }

            if (gitignore_monitor != null) {
                gitignore_monitor.cancel ();
            }
        }

        public string get_current_branch () {
            try {
                var head = git_repo.get_head ();
                if (head.is_branch ()) {
                    return ((Ggit.Branch)head).get_name ();
                }
            } catch (Error e) {
                warning ("Could not get current branch name - %s", e.message);
            }

            return "";
        }

        public string[] get_local_branches () {
            string[] branches = {};
            try {
                var branch_enumerator = git_repo.enumerate_branches (Ggit.BranchType.LOCAL);
                foreach (Ggit.Ref branch_ref in branch_enumerator) {
                    if (branch_ref is Ggit.Branch) {
                        branches += ((Ggit.Branch)branch_ref).get_name ();
                    }
                }
            } catch (Error e) {
                warning ("Could not enumerate branches %s", e.message);
            }

            return branches;
        }

        public void change_branch (string new_branch_name) throws Error {
            var branch = git_repo.lookup_branch (new_branch_name, Ggit.BranchType.LOCAL);
            git_repo.set_head (((Ggit.Ref)branch).get_name ());
            branch_name = new_branch_name;
        }

        private bool do_update = false;
        public void update () {
            if (update_timer_id == 0) {
                update_timer_id = Timeout.add (150, () => {
                    if (do_update) {
                        try {
                            var head = git_repo.get_head ();
                            if (head.is_branch ()) {
                                branch_name = ((Ggit.Branch)head).get_name ();
                            }
                        } catch (Error e) {
                            warning ("An error occured while fetching the current git branch name: %s", e.message);
                        }

                        //SourceList shows files in working dir so only want status for those for now.
                        // No callback generated for current files.
                        //TODO Distinguish new untracked files from new tracked files
                        var options = new Ggit.StatusOptions (Ggit.StatusOption.INCLUDE_UNTRACKED,
                                                              Ggit.StatusShow.WORKDIR_ONLY,
                                                              null);
                        try {
                            status_change = false;
                            map_index = map_index == 0 ? 1 : 0;
                            old_map_index = map_index == 0 ? 1 : 0;

                            map_in_use.clear ();

                            git_repo.file_status_foreach (options, check_each_git_status);

                            if (status_change || map_in_use.size != old_map.size) {
                                file_status_change ();
                            }
                        } catch (Error e) {
                            critical ("Error enumerating git status: %s", e.message);
                        }

                        do_update = false;
                        update_timer_id = 0;
                        return Source.REMOVE;
                    } else {
                        do_update = true;
                        return Source.CONTINUE;
                    }
                });
            } else {
                do_update = false;
            }
        }

        private bool status_change = false;
        private int check_each_git_status (string path, Ggit.StatusFlags status) {
            map_in_use.@set (path, status);

            if (old_map.has_key (path)) {
                if (status == old_map.@get (path)) {
                    return 0;
                }
            }

            status_change = true;
            return 0;
        }
    }
}
