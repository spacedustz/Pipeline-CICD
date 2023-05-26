package com.cicd

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication
class PipelineCicdApplication

fun main(args: Array<String>) {
    runApplication<PipelineCicdApplication>(*args)
}
