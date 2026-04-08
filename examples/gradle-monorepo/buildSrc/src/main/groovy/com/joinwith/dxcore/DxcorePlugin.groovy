package com.joinwith.dxcore

import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.tasks.CacheableTask

class DxcorePlugin implements Plugin<Project> {
    void apply(Project project) {
        project.evaluationDependsOnChildren()

        project.tasks.register('exportDxcoreGraph') {
            doLast {
                def allTasks = collectReachableTasks(project)
                def taskList = buildTaskList(allTasks)
                println groovy.json.JsonOutput.toJson([tasks: taskList])
            }
        }
    }

    /** Collect tasks reachable from each subproject's "build" goal. */
    private static List<org.gradle.api.Task> collectReachableTasks(Project project) {
        def visited = [] as Set
        project.subprojects.each { subproject ->
            def buildTask = subproject.tasks.findByName('build')
            if (buildTask) {
                collectReachable(buildTask, visited)
            }
        }
        return visited.toList()
    }

    /** Build the full task list with cacheable flags. No contraction —
     *  the coordinator handles that via its scheduler plugin. */
    private static List<Map> buildTaskList(List<org.gradle.api.Task> allTasks) {
        def cacheableIds = allTasks
            .findAll { it.getClass().isAnnotationPresent(CacheableTask) }
            .collect { it.path } as Set

        def allIds = allTasks.collect { it.path } as Set

        return allTasks.collect { task ->
            def deps = task.taskDependencies.getDependencies(task)
                .findAll { allIds.contains(it.path) }
                .collect { it.path }
                .sort()

            [
                taskId      : task.path,
                'package'   : task.project.name,
                task        : task.name,
                command     : "./gradlew ${task.path}",
                cacheable   : cacheableIds.contains(task.path),
                dependencies: deps
            ]
        }
    }

    /** Recursively collect all tasks reachable from a root task via dependencies. */
    private static void collectReachable(
            org.gradle.api.Task task, Set<org.gradle.api.Task> visited) {
        if (!visited.add(task)) return
        task.taskDependencies.getDependencies(task).each { dep ->
            collectReachable(dep, visited)
        }
    }
}
