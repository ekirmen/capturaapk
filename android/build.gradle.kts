allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    project.plugins.withType(com.android.build.gradle.BasePlugin::class.java) {
        val android = project.extensions.getByName("android") as com.android.build.gradle.BaseExtension
        android.compileSdkVersion(34)
        if (android.namespace == null) {
            android.namespace = "com.example.${project.name.replace("-", "_").replace(":", "_")}"
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
