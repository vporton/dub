/**
	Representing a full project, with a root Package and several dependencies.

	Copyright: © 2012-2013 Matthias Dondorff
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff, Sönke Ludwig
*/
module dub.project;

import dub.compilers.compiler;
import dub.dependency;
import dub.internal.utils;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.url;
import dub.package_;
import dub.packagemanager;
import dub.packagesupplier;
import dub.generators.generator;


// todo: cleanup imports.
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.process;
import std.string;
import std.typecons;
import std.zip;
import std.encoding : sanitize;

/// Representing a full project, with a root Package and several dependencies.
class Project {
	private {
		PackageManager m_packageManager;
		Json m_packageSettings;
		Package m_rootPackage;
		Package[] m_dependencies;
		Package[][Package] m_dependees;
		SelectedVersions m_selectedVersions;
	}

	this(PackageManager package_manager, Path project_path)
	{
		Package pack;
		if (!Package.isPackageAt(project_path)) {
			logWarn("There was no package description found for the application in '%s'.", m_rootPackage.path.toNativeString());
			auto json = Json.emptyObject;
			json.name = "unknown";
			pack = new Package(json, project_path);
		} else {
			pack = package_manager.getPackage(project_path); 
		}

		this(package_manager, pack);
	}

	this(PackageManager package_manager, Package pack)
	{
		m_packageManager = package_manager;
		m_rootPackage = pack;
		m_packageSettings = Json.emptyObject;

		try m_packageSettings = jsonFromFile(m_rootPackage.path ~ ".dub/dub.json", true);
		catch(Exception t) logDiagnostic("Failed to read .dub/dub.json: %s", t.msg);

		try m_selectedVersions = new SelectedVersions(m_rootPackage.path ~ SelectedVersions.defaultFile);
		catch(Exception e) {
			logDiagnostic("A " ~ SelectedVersions.defaultFile ~ " file was not found or failed to load:\n%s", e.msg);
			m_selectedVersions = new SelectedVersions;
		}

		reinit();
	}

	/// Gathers information
	@property string info()
	const {
		if(!m_rootPackage)
			return "-Unrecognized application in '"~m_rootPackage.path.toNativeString()~"' (probably no package.json in this directory)";
		string s = "-Application identifier: " ~ m_rootPackage.name;
		s ~= "\n" ~ m_rootPackage.generateInfoString();
		s ~= "\n-Retrieved dependencies:";
		foreach(p; m_dependencies)
			s ~= "\n" ~ p.generateInfoString();
		return s;
	}

	/// Gets all retrieved packages as a "packageId" = "version" associative array
	@property string[string] cachedPackagesIDs() const {
		string[string] pkgs;
		foreach(p; m_dependencies)
			pkgs[p.name] = p.vers;
		return pkgs;
	}

	/// List of retrieved dependency Packages
	@property const(Package[]) dependencies() const { return m_dependencies; }
	
	/// Main package.
	@property inout(Package) rootPackage() inout { return m_rootPackage; }

	/// The versions to use for all dependencies. Call reinit() after changing these.
	@property inout(SelectedVersions) selections() inout { return m_selectedVersions; }

	/** Allows iteration of the dependency tree in topological order
	*/
	int delegate(int delegate(ref const Package)) getTopologicalPackageList(bool children_first = false, in Package root_package = null, string[string] configs = null)
	const {
		const(Package) rootpack = root_package ? root_package : m_rootPackage;
	
		int iterator(int delegate(ref const Package) del)
		{
			int ret = 0;
			bool[const(Package)] visited;
			void perform_rec(in Package p){
				if( p in visited ) return;
				visited[p] = true;

				if( !children_first ){
					ret = del(p);
					if( ret ) return;
				}

				auto cfg = configs.get(p.name, null);

				foreach (dn, dv; p.dependencies) {
					// filter out dependencies not in the current configuration set
					if (!p.hasDependency(dn, cfg)) continue;
					auto dependency = getDependency(dn, dv.optional);
					if(dependency) perform_rec(dependency);
					if( ret ) return;
				}

				if( children_first ){
					ret = del(p);
					if( ret ) return;
				}
			}
			perform_rec(rootpack);
			return ret;
		}
		
		return &iterator;
	}

	inout(Package) getDependency(string name, bool isOptional)
	inout {
		foreach(dp; m_dependencies)
			if( dp.name == name )
				return dp;
		if(!isOptional) throw new Exception("Unknown dependency: "~name);
		else return null;
	}

	string getDefaultConfiguration(BuildPlatform platform, bool allow_non_library_configs = true)
	const {
		auto cfgs = getPackageConfigs(platform, null, allow_non_library_configs);
		return cfgs[m_rootPackage.name];
	}

	/// Rereads the applications state.
	void reinit()
	{
		m_dependencies = null;
		m_packageManager.refresh(false);

		// some basic package lint
		m_rootPackage.warnOnSpecialCompilerFlags();
		if (m_rootPackage.name != m_rootPackage.name.toLower()) {
			logWarn(`WARNING: DUB package names should always be lower case, please change `
				~ `to {"name": "%s"}. You can use {"targetName": "%s"} to keep the current `
				~ `executable name.`,
				m_rootPackage.name.toLower(), m_rootPackage.name);
		}

		foreach (dn, ds; m_rootPackage.dependencies)
			if (ds.isExactVersion && ds.version_.isBranch) {
				logWarn("WARNING: A deprecated branch based version specification is used "
					~ "for the dependency %s. Please use numbered versions instead. Also "
					~ "note that you can still use the %s file to override a certain "
					~ "dependency to use a branch instead.",
					dn, SelectedVersions.defaultFile);
			}

		void collectDependenciesRec(Package pack)
		{
			logDebug("Collecting dependencies for %s", pack.name);
			foreach (name, original_vspec; pack.dependencies) {
				if (!m_selectedVersions.hasSelectedVersion(name)) {
					logDiagnostic("Version selection for dependency %s of %s is missing.",
						name, pack.name);
					continue;
				}

				Dependency vspec = m_selectedVersions.selectedVersion(name);

				Package p;
				if (!vspec.path.empty) {
					Path path = vspec.path;
					if (!path.absolute) path = pack.path ~ path;
					logDiagnostic("Adding local %s %s", path, vspec.version_);
					p = m_packageManager.getTemporaryPackage(path, vspec.version_);
				} else {
					p = m_packageManager.getBestPackage(name, vspec);
				}

				if (!p) {
					logDiagnostic("Missing dependency %s %s of %s", name, vspec, pack.name);
					continue;
				}

				if (!m_dependencies.canFind(p)) {
					logDiagnostic("Found dependency %s %s", name, vspec.toString());
					m_dependencies ~= p;
					p.warnOnSpecialCompilerFlags();
					collectDependenciesRec(p);
				}

				m_dependees[p] ~= pack;
				//enforce(p !is null, "Failed to resolve dependency "~name~" "~vspec.toString());
			}
		}
		collectDependenciesRec(m_rootPackage);
	}

	/// Returns the applications name.
	@property string name() const { return m_rootPackage ? m_rootPackage.name : "app"; }

	@property string[] configurations() const { return m_rootPackage.configurations; }

	/// Returns a map with the configuration for all packages in the dependency tree. 
	string[string] getPackageConfigs(in BuildPlatform platform, string config, bool allow_non_library = true)
	const {
		struct Vertex { string pack, config; }
		struct Edge { size_t from, to; }

		Vertex[] configs;
		Edge[] edges;
		string[][string] parents;
		parents[m_rootPackage.name] = null;
		foreach (p; getTopologicalPackageList())
			foreach (d; p.dependencies.byKey)
				parents[d] ~= p.name;


		size_t createConfig(string pack, string config) {
			foreach (i, v; configs)
				if (v.pack == pack && v.config == config)
					return i;
			logDebug("Add config %s %s", pack, config);
			configs ~= Vertex(pack, config);
			return configs.length-1;
		}

		bool haveConfig(string pack, string config) {
			return configs.any!(c => c.pack == pack && c.config == config);
		}

		size_t createEdge(size_t from, size_t to) {
			auto idx = edges.countUntil(Edge(from, to));
			if (idx >= 0) return idx;
			logDebug("Including %s %s -> %s %s", configs[from].pack, configs[from].config, configs[to].pack, configs[to].config);
			edges ~= Edge(from, to);
			return edges.length-1;
		}

		void removeConfig(size_t i) {
			logDebug("Eliminating config %s for %s", configs[i].config, configs[i].pack);
			configs = configs.remove(i);
			edges = edges.filter!(e => e.from != i && e.to != i).array();
			foreach (ref e; edges) {
				if (e.from > i) e.from--;
				if (e.to > i) e.to--;
			}
		}

		bool isReachable(string pack, string conf) {
			if (pack == configs[0].pack && configs[0].config == conf) return true;
			foreach (e; edges)
				if (configs[e.to].pack == pack && configs[e.to].config == conf)
					return true;
			return false;
			//return (pack == configs[0].pack && conf == configs[0].config) || edges.canFind!(e => configs[e.to].pack == pack && configs[e.to].config == config);
		}

		bool isReachableByAllParentPacks(size_t cidx) {
			bool[string] r;
			foreach (p; parents[configs[cidx].pack]) r[p] = false;
			foreach (e; edges) {
				if (e.to != cidx) continue;
				if (auto pp = configs[e.from].pack in r) *pp = true;
			}
			foreach (bool v; r) if (!v) return false;
			return true;
		}

		// create a graph of all possible package configurations (package, config) -> (subpackage, subconfig)
		void determineAllConfigs(in Package p)
		{
			// first, add all dependency configurations
			foreach (dn; p.dependencies.byKey) {
				auto dp = getDependency(dn, true);
				if (!dp) continue;
				determineAllConfigs(dp);
			}

			// for each configuration, determine the configurations usable for the dependencies
			outer: foreach (c; p.getPlatformConfigurations(platform, p is m_rootPackage && allow_non_library)) {
				string[][string] depconfigs;
				foreach (dn; p.dependencies.byKey) {
					auto dp = getDependency(dn, true);
					if (!dp) continue;

					string[] cfgs;
					auto subconf = p.getSubConfiguration(c, dp, platform);
					if (!subconf.empty) cfgs = [subconf];
					else cfgs = dp.getPlatformConfigurations(platform);
					cfgs = cfgs.filter!(c => haveConfig(dn, c)).array;

					// if no valid configuration was found for a dependency, don't include the
					// current configuration
					if (!cfgs.length) {
						logDebug("Skip %s %s (missing configuration for %s)", p.name, c, dp.name);
						continue outer;
					}
					depconfigs[dn] = cfgs;
				}

				// add this configuration to the graph
				size_t cidx = createConfig(p.name, c);
				foreach (dn; p.dependencies.byKey)
					foreach (sc; depconfigs.get(dn, null))
						createEdge(cidx, createConfig(dn, sc));
			}
		}
		if (config.length) createConfig(m_rootPackage.name, config);
		determineAllConfigs(m_rootPackage);

		// successively remove configurations until only one configuration per package is left
		bool changed;
		do {
			// remove all configs that are not reachable by all parent packages
			changed = false;
			for (size_t i = 0; i < configs.length; ) {
				if (!isReachableByAllParentPacks(i)) {
					logDebug("NOT REACHABLE by (%s):", parents[configs[i].pack]);
					removeConfig(i);
					changed = true;
				} else i++;
			}

			// when all edges are cleaned up, pick one package and remove all but one config
			if (!changed) {
				foreach (p; getTopologicalPackageList()) {
					size_t cnt = 0;
					for (size_t i = 0; i < configs.length; ) {
						if (configs[i].pack == p.name) {
							if (++cnt > 1) {
								logDebug("NON-PRIMARY:");
								removeConfig(i);
							} else i++;
						} else i++;
					}
					if (cnt > 1) {
						changed = true;
						break;
					}
				}
			}
		} while (changed);

		// print out the resulting tree
		foreach (e; edges) logDebug("    %s %s -> %s %s", configs[e.from].pack, configs[e.from].config, configs[e.to].pack, configs[e.to].config);

		// return the resulting configuration set as an AA
		string[string] ret;
		foreach (c; configs) {
			assert(ret.get(c.pack, c.config) == c.config, format("Conflicting configurations for %s found: %s vs. %s", c.pack, c.config, ret[c.pack]));
			logDebug("Using configuration '%s' for %s", c.config, c.pack);
			ret[c.pack] = c.config;
		}

		// check for conflicts (packages missing in the final configuration graph)
		foreach (p; getTopologicalPackageList())
			enforce(p.name in ret, "Could not resolve configuration for package "~p.name);

		return ret;
	}

	/**
	 * Fills dst with values from this project.
	 *
	 * dst gets initialized according to the given platform and config. 
	 *
	 * Params:
	 *   dst = The BuildSettings struct to fill with data.
	 *   platform = The platform to retrieve the values for.
	 *   config = Values of the given configuration will be retrieved.
	 *   root_package = If non null, use it instead of the project's real root package.
	 *   shallow = If true, collects only build settings for the main package (including inherited settings) and doesn't stop on target type none and sourceLibrary.
	 */
	void addBuildSettings(ref BuildSettings dst, in BuildPlatform platform, string config, in Package root_package = null, bool shallow = false)
	const {
		auto configs = getPackageConfigs(platform, config);

		foreach (pkg; this.getTopologicalPackageList(false, root_package, configs)) {
			auto pkg_path = pkg.path.toNativeString();
			dst.addVersions(["Have_" ~ stripDlangSpecialChars(pkg.name)]);

			assert(pkg.name in configs, "Missing configuration for "~pkg.name);
			logDebug("Gathering build settings for %s (%s)", pkg.name, configs[pkg.name]);
			
			auto psettings = pkg.getBuildSettings(platform, configs[pkg.name]);
			if (psettings.targetType != TargetType.none) {
				if (shallow && pkg !is m_rootPackage)
					psettings.sourceFiles = null;
				processVars(dst, pkg_path, psettings);
				if (psettings.importPaths.empty)
					logWarn(`Package %s (configuration "%s") defines no import paths, use {"importPaths": [...]} or the default package directory structure to fix this.`, pkg.name, configs[pkg.name]);
				if (psettings.mainSourceFile.empty && pkg is m_rootPackage && psettings.targetType == TargetType.executable)
					logWarn(`Executable configuration "%s" of package %s defines no main source file, this may cause certain build modes to fail. Add an explicit "mainSourceFile" to the package description to fix this.`, configs[pkg.name], pkg.name);
			}
			if (pkg is m_rootPackage) {
				if (!shallow) {
					enforce(psettings.targetType != TargetType.none, "Main package has target type \"none\" - stopping build.");
					enforce(psettings.targetType != TargetType.sourceLibrary, "Main package has target type \"sourceLibrary\" which generates no target - stopping build.");
				}
				dst.targetType = psettings.targetType;
				dst.targetPath = psettings.targetPath;
				dst.targetName = psettings.targetName;
				dst.workingDirectory = processVars(psettings.workingDirectory, pkg_path, true);
				if (psettings.mainSourceFile.length)
					dst.mainSourceFile = processVars(psettings.mainSourceFile, pkg_path, true);
			}
		}

		// always add all version identifiers of all packages
		foreach (pkg; this.getTopologicalPackageList(false, null, configs)) {
			auto psettings = pkg.getBuildSettings(platform, configs[pkg.name]);
			dst.addVersions(psettings.versions);
		}
	}

	void addBuildTypeSettings(ref BuildSettings dst, in BuildPlatform platform, string build_type)
	{
		bool usedefflags = !(dst.requirements & BuildRequirements.noDefaultFlags);
		if (usedefflags) {
			BuildSettings btsettings;
			m_rootPackage.addBuildTypeSettings(btsettings, platform, build_type);
			processVars(dst, m_rootPackage.path.toNativeString(), btsettings);
		}
	}

	/// Determines if the given dependency is already indirectly referenced by other dependencies of pack.
	bool isRedundantDependency(in Package pack, in Package dependency)
	const {
		foreach (dep; pack.dependencies.byKey) {
			auto dp = getDependency(dep, true);
			if (!dp) continue;
			if (dp is dependency) continue;
			foreach (ddp; getTopologicalPackageList(false, dp))
				if (ddp is dependency) return true;
		}
		return false;
	}

	/*bool iterateDependencies(bool delegate(Package pack, string dep_name, Dependency dep_spec) del)
	{
		bool all_found = true;

		bool[string] visited;
		void iterate(Package pack)
		{
			if (pack.name in visited) return;
			visited[pack.name] = true;

			foreach (dn, ds; pack.dependencies) {
				auto dep = del(pack, dn, ds);
				if (dep) iterateDependencies(dep);
				else all_found = false;
			}
		}

		return all_found;
	}*/

	/// Outputs a JSON description of the project, including its deoendencies.
	void describe(ref Json dst, BuildPlatform platform, string config)
	{
		dst.mainPackage = m_rootPackage.name; // deprecated
		dst.rootPackage = m_rootPackage.name;

		auto configs = getPackageConfigs(platform, config);

		auto mp = Json.emptyObject;
		m_rootPackage.describe(mp, platform, config);
		dst.packages = Json([mp]);

		foreach (dep; m_dependencies) {
			auto dp = Json.emptyObject;
			dep.describe(dp, platform, configs[dep.name]);
			dst.packages = dst.packages.get!(Json[]) ~ dp;
		}
	}

	void saveSelections()
	{
		assert(m_selectedVersions !is null, "Cannot save selections for non-disk based project (has no selections).");
		m_selectedVersions.save(m_rootPackage.path ~ SelectedVersions.defaultFile);
	}

	private bool needsUpToDateCheck(Package pack) {
		version (none) { // needs to be updated for the new package system (where no project local packages exist)
			try {
				auto time = m_packageSettings["dub"]["lastUpdate"].opt!(Json[string]).get(pack.name, Json("")).get!string;
				if( !time.length ) return true;
				return (Clock.currTime() - SysTime.fromISOExtString(time)) > dur!"days"(1);
			} catch(Exception t) return true;
		} else return false;
	}
		
	private void markUpToDate(string packageId) {
		logDebug("markUpToDate(%s)", packageId);
		Json create(ref Json json, string object) {
			if( object !in json ) json[object] = Json.emptyObject;
			return json[object];
		}
		create(m_packageSettings, "dub");
		create(m_packageSettings["dub"], "lastUpdate");
		m_packageSettings["dub"]["lastUpdate"][packageId] = Json( Clock.currTime().toISOExtString() );

		writeDubJson();
	}

	private void writeDubJson() {
		// don't bother to write an empty file
		if( m_packageSettings.length == 0 ) return;

		try {
			logDebug("writeDubJson");
			auto dubpath = m_rootPackage.path~".dub";
			if( !exists(dubpath.toNativeString()) ) mkdir(dubpath.toNativeString());
			auto dstFile = openFile((dubpath~"dub.json").toString(), FileMode.CreateTrunc);
			scope(exit) dstFile.close();
			dstFile.writePrettyJsonString(m_packageSettings);
		} catch( Exception e ){
			logWarn("Could not write .dub/dub.json.");
		}
	}
}

/// Actions to be performed by the dub
struct Action {
	enum Type {
		fetch,
		remove,
		conflict,
		failure
	}

	immutable {
		Type type;
		string packageId;
		PlacementLocation location;
		Dependency vers;
		Version existingVersion;
	}
	const Package pack;
	const Dependency[string] issuer;

	static Action get(string pkg, PlacementLocation location, in Dependency dep, Dependency[string] context, Version old_version = Version.UNKNOWN)
	{
		return Action(Type.fetch, pkg, location, dep, context, old_version);
	}

	static Action remove(Package pkg, Dependency[string] context)
	{
		return Action(Type.remove, pkg, context);
	}

	static Action conflict(string pkg, in Dependency dep, Dependency[string] context)
	{
		return Action(Type.conflict, pkg, PlacementLocation.userWide, dep, context);
	}

	static Action failure(string pkg, in Dependency dep, Dependency[string] context)
	{
		return Action(Type.failure, pkg, PlacementLocation.userWide, dep, context);
	}

	private this(Type id, string pkg, PlacementLocation location, in Dependency d, Dependency[string] issue, Version existing_version = Version.UNKNOWN)
	{
		this.type = id;
		this.packageId = pkg;
		this.location = location;
		this.vers = d;
		this.issuer = issue;
		this.existingVersion = existing_version;
	}

	private this(Type id, Package pkg, Dependency[string] issue)
	{
		pack = pkg;
		type = id;
		packageId = pkg.name;
		vers = cast(immutable)Dependency(pkg.ver);
		issuer = issue;
	}

	string toString() const {
		return to!string(type) ~ ": " ~ packageId ~ ", " ~ to!string(vers);
	}
}


enum UpdateOptions
{
	none = 0,
	upgrade = 1<<1, /// Upgrade existing packages
	preRelease = 1<<2, /// inclde pre-release versions in upgrade
	forceRemove = 1<<3, /// Force removing package folders, which contain unknown files
	select = 1<<4, /// Update the dub.selections.json file with the upgraded versions
	printUpgradesOnly = 1<<5, /// Instead of downloading new packages, just print a message to notify the user of their existence
}


/// Indicates where a package has been or should be placed to.
enum PlacementLocation {
	/// Packages retrived with 'local' will be placed in the current folder 
	/// using the package name as destination.
	local,
	/// Packages with 'userWide' will be placed in a folder accessible by
	/// all of the applications from the current user.
	userWide,
	/// Packages retrieved with 'systemWide' will be placed in a shared folder,
	/// which can be accessed by all users of the system.
	systemWide
}

void processVars(ref BuildSettings dst, string project_path, BuildSettings settings, bool include_target_settings = false)
{
	dst.addDFlags(processVars(project_path, settings.dflags));
	dst.addLFlags(processVars(project_path, settings.lflags));
	dst.addLibs(processVars(project_path, settings.libs));
	dst.addSourceFiles(processVars(project_path, settings.sourceFiles, true));
	dst.addImportFiles(processVars(project_path, settings.importFiles, true));
	dst.addStringImportFiles(processVars(project_path, settings.stringImportFiles, true));
	dst.addCopyFiles(processVars(project_path, settings.copyFiles, true));
	dst.addVersions(processVars(project_path, settings.versions));
	dst.addDebugVersions(processVars(project_path, settings.debugVersions));
	dst.addImportPaths(processVars(project_path, settings.importPaths, true));
	dst.addStringImportPaths(processVars(project_path, settings.stringImportPaths, true));
	dst.addPreGenerateCommands(processVars(project_path, settings.preGenerateCommands));
	dst.addPostGenerateCommands(processVars(project_path, settings.postGenerateCommands));
	dst.addPreBuildCommands(processVars(project_path, settings.preBuildCommands));
	dst.addPostBuildCommands(processVars(project_path, settings.postBuildCommands));
	dst.addRequirements(settings.requirements);
	dst.addOptions(settings.options);

	if (include_target_settings) {
		dst.targetType = settings.targetType;
		dst.targetPath = processVars(settings.targetPath, project_path, true);
		dst.targetName = settings.targetName;
		dst.workingDirectory = processVars(settings.workingDirectory, project_path, true);
		if (settings.mainSourceFile.length)
			dst.mainSourceFile = processVars(settings.mainSourceFile, project_path, true);
	}
}

private string[] processVars(string project_path, string[] vars, bool are_paths = false)
{
	auto ret = appender!(string[])();
	processVars(ret, project_path, vars, are_paths);
	return ret.data;

}
private void processVars(ref Appender!(string[]) dst, string project_path, string[] vars, bool are_paths = false)
{
	foreach (var; vars) dst.put(processVars(var, project_path, are_paths));
}

private string processVars(string var, string project_path, bool is_path)
{
	auto idx = std.string.indexOf(var, '$');
	if (idx >= 0) {
		auto vres = appender!string();
		while (idx >= 0) {
			if (idx+1 >= var.length) break;
			if (var[idx+1] == '$') {
				vres.put(var[0 .. idx+1]);
				var = var[idx+2 .. $];
			} else {
				vres.put(var[0 .. idx]);
				var = var[idx+1 .. $];

				size_t idx2 = 0;
				while( idx2 < var.length && isIdentChar(var[idx2]) ) idx2++;
				auto varname = var[0 .. idx2];
				var = var[idx2 .. $];

				string env_variable;
				if( varname == "PACKAGE_DIR" ) vres.put(project_path);
				else if( (env_variable = environment.get(varname)) != null) vres.put(env_variable);
				else enforce(false, "Invalid variable: "~varname);
			}
			idx = std.string.indexOf(var, '$');
		}
		vres.put(var);
		var = vres.data;
	}
	if (is_path) {
		auto p = Path(var);
		if (!p.absolute) {
			logDebug("Fixing relative path: %s ~ %s", project_path, p.toNativeString());
			p = Path(project_path) ~ p;
		}
		return p.toNativeString();
	} else return var;
}

private bool isIdentChar(dchar ch)
{
	return ch >= 'A' && ch <= 'Z' || ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '_';
}

string stripDlangSpecialChars(string s) 
{
	import std.array;
	import std.uni;
	auto ret = appender!string();
	foreach(ch; s)
		ret.put(isIdentChar(ch) ? ch : '_');
	return ret.data;
}

class SelectedVersions {
	private struct Selected {
		Version version_;
		//Dependency[string] packages;	
	}
	private {
		enum FileVersion = 1;
		Selected[string] m_selectedVersions;
	}

	enum defaultFile = "dub.selections.json";

	this() {}

	this(Path path)
	{
		auto json = jsonFromFile(path);
		deserialize(json);
	}

	void clean()
	{
		m_selectedVersions = null;
	}

	void set(SelectedVersions versions)
	{
		m_selectedVersions = versions.m_selectedVersions.dup;
	}

	void selectVersion(string packageId, Version version_)
	{
		m_selectedVersions[packageId] = Selected(version_/*, issuer*/);
	}

	bool hasSelectedVersion(string packageId)
	const {
		return (packageId in m_selectedVersions) !is null;
	}

	Dependency selectedVersion(string packageId)
	const {
		enforce(hasSelectedVersion(packageId));
		return Dependency(m_selectedVersions[packageId].version_);
	}

	void save(Path path)
	const {
		Json json = serialize();
		auto file = openFile(path, FileMode.CreateTrunc);
		scope(exit) file.close();
		file.writePrettyJsonString(json);
	}

	private Json serialize()
	const {
		Json json = serializeToJson(m_selectedVersions);
		Json serialized = Json.emptyObject;
		serialized.fileVersion = FileVersion;
		serialized.versions = Json.emptyObject;
		foreach (p, v; m_selectedVersions)
			serialized.versions[p] = v.version_.toString();
		return serialized;
	}

	private void deserialize(Json json)
	{
		enforce(cast(int)json["fileVersion"] == FileVersion, "Mismatched dub.select.json version: " ~ to!string(cast(int)json["fileVersion"]) ~ "vs. " ~to!string(FileVersion));
		clean();
		scope(failure) clean();
		foreach (string p, v; json.versions)
			m_selectedVersions[p] = Selected(Version(v.get!string));
	}
}
