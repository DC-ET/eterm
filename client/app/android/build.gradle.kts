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

// 第三方插件模块跳过 release lint（lintVital*）：JDK17 下 AGP lint 解析插件 Java 源码即崩
// （NoSuchMethodError List.removeLast，file_selector_android 触发，AGP/lint 已知 bug）。
// 插件侧 lint 问题不可由本仓库修复，仅对非 :app 模块禁用 lintVital 任务；
// :app 自身的 release lint 保留。
subprojects {
    if (name != "app") {
        tasks.whenTaskAdded {
            if (name.startsWith("lintVital")) {
                enabled = false
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
