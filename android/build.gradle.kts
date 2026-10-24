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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// ---- यहाँ से बिल्कुल सही सुधरा हुआ कोड जोड़ा गया है ----
subprojects {
    plugins.configureEach {
        if (this is com.android.build.gradle.api.AndroidBasePlugin) {
            val android = project.extensions.getByName("android") as com.android.build.gradle.BaseExtension
            android.compileSdkVersion(36)
        }
    }
}
